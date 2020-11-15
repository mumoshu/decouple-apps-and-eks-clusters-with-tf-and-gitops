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
