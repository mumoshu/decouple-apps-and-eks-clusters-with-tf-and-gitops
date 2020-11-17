# Fork of https://github.com/chatwork/dockerfiles/blob/master/argocd-helmfile/Dockerfile
# to add kustomize

FROM chatwork/argocd-helmfile:1.7.8-0.134.1

USER root

RUN \
  cd /usr/local/bin && \
  curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash && \
  kustomize version

USER argocd
