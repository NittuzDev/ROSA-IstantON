export AWS_REGION=''
export AWS_ACCOUNT=''
export REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export IMAGE="${REGISTRY}/instanton-demo:1.0.0"

aws ecr describe-repositories --repository-names instanton-demo --region "${AWS_REGION}" \
  || aws ecr create-repository --repository-name instanton-demo --region "${AWS_REGION}"

aws ecr get-login-password --region "${AWS_REGION}" \
  | sudo podman login --username AWS --password-stdin "${REGISTRY}"

scripts/build-instanton.sh "${IMAGE}" instanton
sudo podman image inspect "${IMAGE}" --format '{{.Architecture}} {{.Os}}'
sudo podman push "${IMAGE}"






## TEST ##

sudo podman run --rm \
  --cap-add=CHECKPOINT_RESTORE \
  --cap-add=SETPCAP \
  --security-opt seccomp=unconfined \
  --env CRIU_RESTORE_DISABLE_RECOVERY=true \
  --env WLP_LOGGING_CONSOLE_FORMAT=simple \
  -p 9080:9080 \
  "${IMAGE}"