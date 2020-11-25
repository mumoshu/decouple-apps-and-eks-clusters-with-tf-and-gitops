# Managing multiple EKS clusters with Terraform and GitOps

本セッションでは、「EKS へのアプリケーションの円滑なデプロイ」と「EKS クラスタの円滑な入れ替え」をいかに両立させるか、とテーマにします。

## どんなときにクラスタの入れ替えが発生するか（または、入れ替えしたくなるか)

- K8s マイナーバージョンアップ
- SG、IAM Role等の変更

EKS では（アップストリームへの追従状況次第ですが）概ね3ヶ月に一度サポートされる Kubernetes （マイナー）バージョンが追加されます。

Kubernetes の新マイナーバージョンには、特定の API バージョンが廃止されたり、新機能が追加されたりといった変更が含まれます。
それに伴い、以前のバージョンで動いていたアプリケーションが新しいマイナーバージョンでは動かない、といったクラスタ全体に波及する障害が起きる可能性が考えられます。

また、Nodeに割り当てる Security Group や IAM Role を変更する、といった作業も、場合によってはクラスタ全体の障害につながる可能性があります。

上記のような変更は通常 "in-place" で行うと思いますが、前者については Control-Plane の K8s マイナーバージョンを一度上げてしまうと下げることはできない、後者については問題のあった変更を戻すだけでも数十秒程度時間がかかってしまう可能性があります。

SLA的にそれが許されない場合に、何かできることはないのでしょうか？

## 前提条件



## コンセプト

EKS クラスタ一式を Ephemeral だとみなすことで、どこまでクラスタ一式を Disposable, Replaceable にできるか?

# 用語

- ArgoCD クラスタ: ArgoCD が稼働する EKS クラスタ。複数あるターゲットクラスタへのデプロイを中央集権的に管理する。
- ターゲットクラスタ: ArgoCD によるデプロイ先となるクラスタ。基本的にはサービス毎に１つだが、その場合でもクラスタの入れ替え作業中は一時的に２つになる。

# 手順

- Terraform, terraform-provider-{eksctl,helmfile}のインストール
- `terraform apply` で [ArgoCDクラスタ一式](https://github.com/mumoshu/terraform-provider-eksctl/tree/master/examples/productionsetup-alb)のセットアップ
  - 今回はずるして terraform-provider-helmfile の代わりに 単に `helmfile` を使うかもしれません
  - Helmfile: https://github.com/mumoshu/ephemeral-eks/blob/master/helmfile.yaml
- `kubectl apply` で ArgoCD ApplicationSet を作成
- `terraform apply` で [ターゲットクラスタ一式](https://github.com/mumoshu/terraform-provider-eksctl/tree/master/examples/vpcreuse) のセットアップ
  - Helmfile: https://github.com/mumoshu/ephemeral-eks/blob/master/environments/production/podinfo/helmfile.yaml
  - ターゲットクラスタへのデプロイは `terraform apply` 中で行う方法、 `helmfile apply` で行う方法、 ArgoCD に任せる方法がある。それぞれメリデメあり
- `terraform apply` で ArgoCD クラスタ の入れ替え
- `terrafomr apply` で ターゲットクラスタ の入れ替え

# 以下、未整理メモ

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


ターゲットクラスタのPrivate Endpoint Accessを有効化する場合、ArgoCDクラスタ（のノード）からのK8s APIアクセスもPrivateになりSecurity Groupがきくことになるため、両クラスタ側でSecurity Groupの設定が必要

ArgoCDクラスタのSharedNodeSecurityGroupからのアクセスを、アプリクラスタのCluster Security Group(CFN OutputではClusterSecurityGroupId=ControlPlane.ClusterSecurityGroupId)またはAddtional Security Group(CFN OutputではSecurityGroupという名前)のIngressで許可する必要がある。

前者はControl-PlaneとManaged Nodes, 後者はControl-Planeにのみ付与される。
また、前者はControl-PlaneとManaged Nodes、その他のマネージドリソースの相互通信のために利用され、後者はeksctlでは各Unmanaged Nodeからの443へのIngressを許可し、かつUnmanaged Node側からみてControl-Planeからの443(extensions api server)と1045-65535のIngress許可に使われている。

今回はArgoCDから対象クラスタのPrivate Endpoint経由でK8s APIのみアクセスできればよいので、Additional Security GroupのIngressでArgoCDクラスタのノード(に付与したSG)からの443を許可すればよい。

セキュリティグループの設定が問題なければ、ArgoCD クラスタの argocd-application-controller 上で以下のようなコマンドを実行することで、疎通確認できる。

```
$ argocd-util kubeconfig https://A3688960450F35B080D39F01CE7128E7.gr7.us-east-2.eks.amazonaws.com foo
$ KUBECONFIG=foo kubectl get no
```

=> ClusterSecurityGroupの追加Ingressってどうやって変更できるんだっけ？(eksctlは対応してないきがする?)

# リンク集

- https://github.com/aws/eks-charts
- https://github.com/argoproj/argo-cd/issues/2347
- https://github.com/argoproj/argo-helm/tree/master/charts/argo-cd
- https://github.com/mumoshu/ephemeral-eks
