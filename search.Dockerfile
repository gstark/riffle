# Search Lambdas (indexer, API, receipts, and proofs). scripts/build-search-image.sh prepares the build context:
# the bundled handlers and the arm64 production node_modules. The build has no RUN steps,
# so an x86_64 machine can build the arm64 image without emulation.
FROM public.ecr.aws/lambda/nodejs:24
COPY . ${LAMBDA_TASK_ROOT}/
CMD ["api-lambda.handler"]
