.PHONY: install lint test build deploy-dev deploy-staging deploy-prod configure-aws configure-github clean
ROLE_NAME ?= github-actions-lambda-deploy
install:
	python -m pip install -r requirements-dev.txt
lint:
	python -m pytest --collect-only -q
test:
	python -m pytest
build:
	sam build
deploy-dev:
	sam deploy --config-env dev
deploy-staging:
	sam deploy --config-env staging
deploy-prod:
	sam deploy --config-env prod
configure-aws:
	@test -n "$(AWS_ACCOUNT_ID)" || (echo "Uso: make configure-aws AWS_ACCOUNT_ID=... [ROLE_NAME=...]"; exit 2)
	./scripts/configure-aws.sh "$(AWS_ACCOUNT_ID)" "$(ROLE_NAME)"
configure-github:
	@test -n "$(ROLE_ARN)" || (echo "Uso: make configure-github ROLE_ARN=arn:..."; exit 2)
	./scripts/configure-github.sh "$(ROLE_ARN)"
clean:
	rm -rf .aws-sam build
