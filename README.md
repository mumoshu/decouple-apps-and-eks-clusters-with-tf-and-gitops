# ephemeral-eks

# ポイント

- ArgoCD クラスタが複数のアプリケーションクラスタを管理する構成を前提とする
- ArgoCD クラスタは Terraform + Helmfileでデプロイする
  - terraform apply 一発
- アプリケーションクラスタは Terraform + Helmfileでセットアップ後、ArgoCD によって非同期でアプリがデプロイされる
- ArgoCD クラスタ自体も Blue/Green で入れ替えられるようにする
  - Blue, Green ArgoCD クラスタのどちらからも同じ IAM Role を Pod が Assume できるようにする
    - ArgoCD に管理される側のクラスタは、ArgoCD クラスタが何個いるかを気にせずに、常に単一の IAM Role に対して aws-auth でアクセス許可を行えばよい
  - ArgoCD Application は、ArgoCD に管理されるクラスタと一緒に作る。
    - ArgoCD に ApplicationSet が実装されれば解決されるかもしれない

# 手順

- ArgoCD クラスタ
- アプリケーションクラスタ

## ArgoCD クラスタ

- argocd-applicationset をビルドする
  ```console
  # https://github.com/argoproj-labs/applicationset#development-instructions
  $ git clone git@github.com:argoproj-labs/applicationset.git
  $ cd applicationset
  $ IMAGE="mumoshu/argocd-applicationset:v0.1.0" make image deploy
  $ docker push mumoshu/argocd-applicationset:v0.1.0
  ```
- ArgoCD 用クラスタをつくる
- `make deps apply`
