.PHONY: tester
tester:
	kubectl apply -f tester.yaml || true
	kubectl wait pod tester --for condition=Ready
	echo 'Run `aws sts get-caller-identity` on the shell to verify the pod IAM role working.'
	kubectl exec -it tester -- bash

.PHONY: initial-password
initial-password:
	@kubectl get pods -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2

.PHONY: port-forward
port-forward:
	kubectl port-forward svc/argocd-server 8080:443

.PHONY: deps
deps:
	if [ ! -e kustomize ]; then \
	  curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash; \
	fi
	mkdir -p ~/.config/kustomize/plugin
	if [ ! -e argocd ]; then \
	  VERSION=$$(curl --silent "https://api.github.com/repos/argoproj/argo-cd/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/'); \
	  curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/$${VERSION}/argocd-darwin-amd64; \
	  chmod +x argocd; \
	fi

.PHONY: apply
apply:
	PATH=$$(pwd):$$PATH helmfile apply

.PHONY: destroy
destroy:
	PATH=$$(pwd):$$PATH helmfile destroy


.PHONY: target/apply
target/apply:
	cd environments/production/podinfo; PATH=$$(pwd):$$PATH helmfile --state-values-set ns=podinfo $(EXTRA_FLAGS) apply

.PHONY: target/destroy
target/destroy:
	cd environments/production/podinfo; PATH=$$(pwd):$$PATH helmfile --state-values-set ns=podinfo $(EXTRA_FLAGS) destroy

.PHONY: image
image:
	docker build -t mumoshu/argocd-helmfile .
	docker push mumoshu/argocd-helmfile
