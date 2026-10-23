#!/usr/bin/env bash
# Builds the search Lambda image (linux/arm64) and pushes it to ECR as "latest".
# Then run `tofu apply` in infra/: the Lambdas use the digest of "latest".
#
#   AWS_PROFILE=automation scripts/build-search-image.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REGION=us-east-2
REPO=$(tofu -chdir=infra output -raw search_repository_url)
OUT=dist/search-image

/bin/rm -rf "$OUT"
/bin/mkdir -p "$OUT"
/bin/cp package.json package-lock.json "$OUT/"
(cd "$OUT" && npm ci --omit=dev --ignore-scripts --os=linux --cpu=arm64 --libc=glibc)

# LanceDB's optional embedding providers are not used. They add hundreds of MB.
# Keep only the arm64 glibc build of the LanceDB native library.
/bin/rm -rf "$OUT"/node_modules/{@huggingface,onnxruntime-common,onnxruntime-node,onnxruntime-web,sharp,@img,openai}
for dir in "$OUT"/node_modules/@lancedb/lancedb-*; do
  [[ "$dir" == */lancedb-linux-arm64-gnu ]] || /bin/rm -rf "$dir"
done

npx esbuild src/search/indexer-lambda.ts src/search/api-lambda.ts \
  --bundle --platform=node --target=node24 --format=esm --packages=external \
  --outdir="$OUT" --out-extension:.js=.mjs
/bin/cp search.Dockerfile "$OUT/Dockerfile"

docker build --platform linux/arm64 --provenance=false -t "$REPO:latest" "$OUT"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO%%/*}"
docker push "$REPO:latest"
