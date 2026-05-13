#!/usr/bin/env python3
"""GR00T-N1.6 AWS 인프라 스택 배포 스크립트.

CloudFormation 스택을 배포하여 필요한 모든 AWS 리소스를 생성하고,
결과값(버킷명, 역할 ARN, ECR URI 등)을 config.yaml에 자동으로 기입합니다.

사용법:
    python infra/deploy_stack.py \
        --bucket-name my-groot-artifacts-20240101 \
        --region us-east-1

    # 멀티 사용자/환경: --alias로 모든 리소스 이름에 postfix 추가
    python infra/deploy_stack.py \
        --alias alice \
        --bucket-name my-groot-artifacts-20240101-alice \
        --region us-east-1
"""

import argparse
import json
import sys
import time
from pathlib import Path

import boto3
import yaml
from botocore.exceptions import ClientError

# 프로젝트 루트 (sagemaker-vla/)
PROJECT_ROOT = Path(__file__).parent.parent
CFN_TEMPLATE_PATH = Path(__file__).parent / "cloudformation.yaml"
CONFIG_PATH = PROJECT_ROOT / "config.yaml"
DEPLOY_LAMBDA_SRC_PATH = PROJECT_ROOT / "pipeline" / "lambda_deploy_endpoint.py"


def get_account_id(session: boto3.Session) -> str:
    sts = session.client("sts")
    return sts.get_caller_identity()["Account"]


def get_default_vpc_and_subnets(session: boto3.Session) -> tuple[str, list[str]]:
    """계정 default VPC ID와 그 VPC 내 모든 subnet ID를 반환합니다.

    Studio 도메인은 PublicInternetOnly 모드라도 VPC + Subnet을 필수로 받습니다.
    """
    ec2 = session.client("ec2")
    vpcs = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])["Vpcs"]
    if not vpcs:
        raise RuntimeError(
            "Default VPC가 없습니다. --vpc-id / --subnet-ids 를 명시해 주세요."
        )
    vpc_id = vpcs[0]["VpcId"]
    subnets = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["Subnets"]
    subnet_ids = [s["SubnetId"] for s in subnets]
    if not subnet_ids:
        raise RuntimeError(f"VPC {vpc_id}에 subnet이 없습니다. --subnet-ids 명시 필요.")
    return vpc_id, subnet_ids


def get_isaac_lab_vpc_and_subnets(
    session: boto3.Session, alias: str
) -> tuple[str, list[str]] | None:
    """IsaacLab-{Latest,Stable}-${alias} 부모 스택의 PrivateSubnetId Output을
    이용해 VPC ID와 subnet 목록을 반환합니다.

    부모 스택 또는 Output이 없으면 None.
    """
    cfn = session.client("cloudformation")
    candidates = [f"IsaacLab-Latest-{alias}", f"IsaacLab-Stable-{alias}"]
    private_subnet_id: str | None = None
    found_stack: str | None = None

    for stack_name in candidates:
        try:
            resp = cfn.describe_stacks(StackName=stack_name)
        except ClientError as e:
            if "does not exist" in str(e) or "ValidationError" in str(e):
                continue
            raise
        stacks = resp.get("Stacks", [])
        if not stacks:
            continue
        outputs = {o["OutputKey"]: o["OutputValue"] for o in stacks[0].get("Outputs", [])}
        private_subnet_id = outputs.get("PrivateSubnetId")
        if private_subnet_id:
            found_stack = stack_name
            break

    if not private_subnet_id or not found_stack:
        return None

    ec2 = session.client("ec2")
    desc = ec2.describe_subnets(SubnetIds=[private_subnet_id])["Subnets"]
    if not desc:
        return None
    vpc_id = desc[0]["VpcId"]
    print(f"IsaacLab 부모 스택 발견: {found_stack} (VPC={vpc_id}, subnet={private_subnet_id})")
    return vpc_id, [private_subnet_id]


def deploy_stack(
    stack_name: str,
    bucket_name: str,
    region: str,
    vpc_id: str,
    subnet_ids: list[str],
    alias: str = "",
    role_name: str = "GR00TSageMakerRole",
    repository_url: str = "",
) -> dict:
    """CloudFormation 스택을 생성 또는 업데이트합니다.

    Args:
        stack_name: CloudFormation 스택 이름.
        bucket_name: S3 버킷 이름 (전 세계 고유해야 함).
        region: AWS 리전.
        vpc_id: SageMaker Studio 도메인용 VPC ID.
        subnet_ids: Studio 도메인용 subnet ID 리스트 (1개 이상).
        alias: 리소스 이름 충돌 방지용 postfix (선택).
        role_name: SageMaker 실행 역할 이름.
        repository_url: CodeBuild 소스 GitHub URL (선택).

    Returns:
        스택 출력값 딕셔너리 (BucketName, SageMakerRoleArn, ECR URIs 등).
    """
    session = boto3.Session(region_name=region)
    cfn = session.client("cloudformation")
    account_id = get_account_id(session)

    template_body = CFN_TEMPLATE_PATH.read_text(encoding="utf-8")
    deploy_lambda_code = DEPLOY_LAMBDA_SRC_PATH.read_text(encoding="utf-8")

    parameters = [
        {"ParameterKey": "BucketName", "ParameterValue": bucket_name},
        {"ParameterKey": "Alias", "ParameterValue": alias},
        {"ParameterKey": "RoleName", "ParameterValue": role_name},
        {"ParameterKey": "RepositoryUrl", "ParameterValue": repository_url},
        {"ParameterKey": "DefaultVpcId", "ParameterValue": vpc_id},
        {"ParameterKey": "DefaultSubnetIds", "ParameterValue": ",".join(subnet_ids)},
        {"ParameterKey": "DeployEndpointLambdaCode", "ParameterValue": deploy_lambda_code},
    ]

    # 스택 존재 여부 확인
    stack_exists = False
    try:
        cfn.describe_stacks(StackName=stack_name)
        stack_exists = True
    except ClientError as e:
        if "does not exist" not in str(e):
            raise

    try:
        if stack_exists:
            print(f"스택 '{stack_name}' 업데이트 중...")
            cfn.update_stack(
                StackName=stack_name,
                TemplateBody=template_body,
                Parameters=parameters,
                Capabilities=["CAPABILITY_NAMED_IAM"],
            )
            waiter = cfn.get_waiter("stack_update_complete")
        else:
            print(f"스택 '{stack_name}' 생성 중...")
            cfn.create_stack(
                StackName=stack_name,
                TemplateBody=template_body,
                Parameters=parameters,
                Capabilities=["CAPABILITY_NAMED_IAM"],
                Tags=[{"Key": "Project", "Value": "GR00T-N1.6"}],
            )
            waiter = cfn.get_waiter("stack_create_complete")

        print("배포 완료 대기 중... (수 분 소요될 수 있습니다)")
        waiter.wait(
            StackName=stack_name,
            WaiterConfig={"Delay": 10, "MaxAttempts": 60},
        )
        print("스택 배포 완료!")

    except ClientError as e:
        if "No updates are to be performed" in str(e):
            print("변경 사항 없음 - 스택이 이미 최신 상태입니다.")
        else:
            raise

    # 출력값 수집
    response = cfn.describe_stacks(StackName=stack_name)
    outputs_raw = response["Stacks"][0].get("Outputs", [])
    outputs = {o["OutputKey"]: o["OutputValue"] for o in outputs_raw}
    outputs["AccountId"] = account_id
    outputs["Region"] = region

    return outputs


def update_config_yaml(outputs: dict) -> None:
    """스택 출력값을 config.yaml에 기입합니다.

    Args:
        outputs: deploy_stack() 반환값.
    """
    config = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))

    alias = outputs.get("Alias", "") or ""
    suffix = f"-{alias}" if alias else ""

    config["aws"]["account_id"] = outputs.get("AccountId", "")
    config["aws"]["alias"] = alias
    config["aws"]["bucket_name"] = outputs.get("BucketName", "")
    config["aws"]["role_arn"] = outputs.get("SageMakerRoleArn", "")
    config["aws"]["region"] = outputs.get("Region", config["aws"]["region"])
    config["ecr"]["training_uri"] = outputs.get("TrainingRepositoryUri", "")
    config["ecr"]["inference_uri"] = outputs.get("InferenceRepositoryUri", "")

    # alias 적용 시 의존 리소스 이름도 함께 갱신
    config.setdefault("codebuild", {})
    config["codebuild"]["training_project"] = outputs.get(
        "TrainingBuildProjectName", f"groot-n16-training-build{suffix}"
    )
    config["codebuild"]["inference_project"] = outputs.get(
        "InferenceBuildProjectName", f"groot-n16-inference-build{suffix}"
    )
    config.setdefault("inference", {})
    config["inference"]["endpoint_name"] = f"groot-n16-endpoint{suffix}"
    config["inference"]["model_package_group"] = f"groot-n16-models{suffix}"

    config.setdefault("mlflow", {})
    config["mlflow"]["tracking_server_arn"] = outputs.get("MlflowTrackingServerArn", "")
    config["mlflow"]["tracking_server_name"] = outputs.get(
        "MlflowTrackingServerName", f"groot-mlflow{suffix}"
    )
    config["mlflow"].setdefault("experiment_name", "groot-n16-finetune")

    config.setdefault("lambda", {})
    config["lambda"]["deploy_endpoint_arn"] = outputs.get("DeployEndpointLambdaArn", "")
    config["lambda"]["deploy_endpoint_name"] = outputs.get(
        "DeployEndpointLambdaName", f"groot-deploy-endpoint{suffix}"
    )

    CONFIG_PATH.write_text(yaml.dump(config, allow_unicode=True, default_flow_style=False), encoding="utf-8")
    print(f"config.yaml 업데이트 완료: {CONFIG_PATH}")


def print_summary(outputs: dict) -> None:
    """배포 결과 요약을 출력합니다."""
    print("\n" + "=" * 60)
    print("  GR00T 인프라 배포 완료!")
    print("=" * 60)
    print(f"  AWS 계정 ID  : {outputs.get('AccountId')}")
    print(f"  리전          : {outputs.get('Region')}")
    print(f"  S3 버킷       : {outputs.get('BucketName')}")
    print(f"  SageMaker 역할: {outputs.get('SageMakerRoleArn')}")
    print(f"  Notebook 역할 : {outputs.get('NotebookRoleArn')}")
    print(f"  학습 ECR URI  : {outputs.get('TrainingRepositoryUri')}")
    print(f"  추론 ECR URI  : {outputs.get('InferenceRepositoryUri')}")
    print(f"  Studio 도메인 : {outputs.get('StudioDomainId')}")
    print(f"  Studio URL    : {outputs.get('StudioDomainUrl')}")
    print(f"  Studio 사용자 : {outputs.get('StudioUserProfileName')}")
    print(f"  MLflow 서버   : {outputs.get('MlflowTrackingServerArn')}")
    print(f"  Deploy Lambda : {outputs.get('DeployEndpointLambdaArn')}")
    print("=" * 60)
    print("\n다음 단계:")
    print("  1. (선택) SSM 파라미터 업데이트:")
    print("       aws ssm put-parameter --name /groot/hf-token --value <HF_TOKEN> --overwrite")
    print("       aws ssm put-parameter --name /groot/wandb-key --value <WANDB_KEY> --overwrite")
    print("  2. 모델 다운로드:")
    print("       python data/download_model.py")
    print("  3. 데이터셋 업로드:")
    print("       python data/upload_dataset.py --local-path ./my-dataset")
    print("  4. SageMaker Studio 접속 (presigned URL):")
    print(
        f"       aws sagemaker create-presigned-domain-url "
        f"--domain-id {outputs.get('StudioDomainId')} "
        f"--user-profile-name {outputs.get('StudioUserProfileName')}"
    )
    print()


DEFAULT_STACK_BASE = "GrootSMTrainingJob"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="GR00T-N1.6 AWS 인프라 스택 배포",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
예시:
  # 기본 (단일 사용자):
  python infra/deploy_stack.py \\
      --bucket-name my-groot-artifacts-20240101 \\
      --region us-east-1

  # 멀티 사용자 (alias로 리소스 이름 충돌 방지):
  python infra/deploy_stack.py \\
      --alias alice \\
      --bucket-name my-groot-artifacts-20240101-alice
        """,
    )
    parser.add_argument("--stack-name", default="",
                        help=f"CloudFormation 스택 이름. 미지정 시 '{DEFAULT_STACK_BASE}' (alias 지정 시 '{DEFAULT_STACK_BASE}-<alias>')")
    parser.add_argument("--alias", default="",
                        help="리소스 이름 충돌 방지용 postfix (예: 사용자 ID). 미지정 시 postfix 없음")
    parser.add_argument("--bucket-name", required=True, help="S3 버킷 이름 (전 세계 고유)")
    parser.add_argument("--region", default="us-east-1", help="AWS 리전 (기본값: us-east-1)")
    parser.add_argument("--role-name", default="GR00TSageMakerRole",
                        help="SageMaker 실행 역할 이름 (alias 지정 시 postfix 추가)")
    parser.add_argument("--repository-url", default="", help="CodeBuild GitHub 소스 URL (선택)")
    parser.add_argument("--vpc-id", default="",
                        help="SageMaker Studio 도메인용 VPC ID. 미지정 시 계정 default VPC 자동 탐지")
    parser.add_argument("--subnet-ids", default="",
                        help="Studio 도메인용 subnet ID 목록 (쉼표 구분). 미지정 시 VPC의 모든 subnet 사용")
    parser.add_argument("--no-update-config", action="store_true", help="config.yaml 자동 업데이트 건너뜀")

    args = parser.parse_args()

    stack_name = args.stack_name or (
        f"{DEFAULT_STACK_BASE}-{args.alias}" if args.alias else DEFAULT_STACK_BASE
    )

    try:
        # VPC / Subnet 결정 우선순위:
        #   1) --vpc-id + --subnet-ids 명시값
        #   2) alias 지정 시 IsaacLab-{Latest,Stable}-${alias} 부모 스택 재사용
        #   3) 계정 default VPC + 모든 subnet
        if args.vpc_id and args.subnet_ids:
            vpc_id = args.vpc_id
            subnet_ids = [s.strip() for s in args.subnet_ids.split(",") if s.strip()]
        elif args.vpc_id or args.subnet_ids:
            print(
                "오류: --vpc-id 와 --subnet-ids 는 함께 지정해야 합니다 "
                "(둘 다 비우면 IsaacLab 부모 스택 또는 default VPC 자동 사용).",
                file=sys.stderr,
            )
            sys.exit(1)
        else:
            session = boto3.Session(region_name=args.region)
            isaac = get_isaac_lab_vpc_and_subnets(session, args.alias) if args.alias else None
            if isaac is not None:
                vpc_id, subnet_ids = isaac
            else:
                vpc_id, subnet_ids = get_default_vpc_and_subnets(session)
                print(f"Default VPC 자동 탐지: vpc_id={vpc_id}, subnets={subnet_ids}")

        outputs = deploy_stack(
            stack_name=stack_name,
            bucket_name=args.bucket_name,
            region=args.region,
            vpc_id=vpc_id,
            subnet_ids=subnet_ids,
            alias=args.alias,
            role_name=args.role_name,
            repository_url=args.repository_url,
        )

        if not args.no_update_config:
            update_config_yaml(outputs)

        print_summary(outputs)

    except ClientError as e:
        print(f"오류: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n취소됨.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
