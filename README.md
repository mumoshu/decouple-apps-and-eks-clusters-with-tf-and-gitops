# Decouple applications and EKS clusters for better multi-clusters management with Terraform and GitOps

A.k.a "Keep canary-deploying applications while swapping EKS clusters with Terraform and GitOps"

本セッションでは、「EKS へのアプリケーションの円滑なデプロイ」と「EKS クラスタの円滑な入れ替え」をいかに両立させるか、とテーマにします。

## EKS へのアプリケーションの円滑なデプロイ

CIで単体・結合・E2Eテストが行われていて、何らかのCIまたはCDによってデプロイ・リリースが(半)自動化されている方は多いのではないでしょうか？

例えば、次のようなケースです。

- CircleCI や CodePipeline+CodeBuild で Rails アプリに対して rspec によるテストを実行していて、それが通ったら手動承認ステップを通してプロダクションやステージング環境にデプロイされる
- デプロイ時には docker build, docker push によるコンテナイメージの作成とアップロードが行われる
- デプロイ時には kustomize build や helm template などによるマニフェストの生成および kubectl apply による適用、または helm install/upgrade による Helm Chart のインストールが発生する

これはもちろん素晴らしいプラクティスなのですが、サービスの規模やアプリケーションの特性によっては、デプロイ後に問題が判明した場合の切り戻しに数十秒〜数分の時間がかかってしまうことがあります。

Kubernetes Deployment でローリングアップデートを採用していて、デプロイ時の影響を最小化するために maxSurge や maxUnavailable を低めの値にしていたり、アプリケーションの起動に時間がかかる場合（例えば起動時にある程度ウォームアップが必要なアプリケーションだと、数分~数十分起動に時間がかかることもあると思います）、またはその両方…などのケースが考えられます。

こうした場合に K8s 界隈だと Open Source の Blue/Green、カナリアデプロイをサポートしてくれるツールがよく使われます。

- Flagger
- Argo Rollout
- Spinnaker

これらのツールはアプリケーションの前段にトラフィックの柔軟な重み付けをサポートしているプロキシサーバがあることを前提としているものも多く、以下のようなもの（や、それが提供するFront Proxy）がよく使われます。

- Envoy
- AppMesh
- Istio
- Linkerd

どれを採用してもよいのですが、本セッションでは App Mesh と Flagger をベースに話を進めます。

## EKS クラスタの円滑な入れ替え

- K8s マイナーバージョンアップ
- SG、IAM Role等の変更

EKS では（アップストリームへの追従状況次第ですが）概ね3ヶ月に一度サポートされる Kubernetes （マイナー）バージョンが追加されます。

Kubernetes の新マイナーバージョンには、特定の API バージョンが廃止されたり、新機能が追加されたりといった変更が含まれます。
それに伴い、以前のバージョンで動いていたアプリケーションが新しいマイナーバージョンでは動かない、といったクラスタ全体に波及する障害が起きる可能性が考えられます。

また、Nodeに割り当てる Security Group や IAM Role を変更する、といった作業も、場合によってはクラスタ全体の障害につながる可能性があります。

上記のような変更は通常 "in-place" で行うと思いますが、前者については Control-Plane の K8s マイナーバージョンを一度上げてしまうと下げることはできない、後者については問題のあった変更を戻すだけでも数十秒程度時間がかかってしまう可能性があります。

SLA的にそれが許されない場合に、何かできることはないのでしょうか？

一つの方法は、ALB や NLB などの後ろに複数の EKS クラスタを配置し、一方のクラスタへのトラフィックの重みを 10% などの十分に小さい値にして、その重みの小さいクラスタを先に更新することです。その後、特にアラート等が上がらないのであれば、その変更は安全とみなしてもう一方のクラスタに全く同じ変更を行います。

個人的にこのパターンを「クラスタ『の』カナリアデプロイ」と呼んでいます。

この方法自体は手動・自動問わず様々な方法で実現可能なのですが、今回は eksctl ベースで行う方法を前提とします。

## 大まかな流れ

クラスタは terraform がカナリアデプロイし、アプリは ArgoCD がカナリアデプロイします。

- クラスタの入れ替え
  - `terraform apply` 一発で「クラスタのカナリアデプロイ」
    - 手前味噌ですが terraform と eksctl を悪魔合体させた [terraform-provider-eksctl](https://github.com/mumoshu/terraform-provider-eksctl) を使います。
    - `eksctl_cluster` リソースで eksctl クラスタを作成します(つくったクラスタは普段どおり eksctl で参照・変更することもできます。エスケープハッチとして)
    - クラスタ作成後の「共通セットアップ」は `helmfile` で行います（ArgoCD ではカナリアデプロイや容易でないものはここでクラスタと一緒にデプロイします。flagger、appmesh-controller、fluentd、また cloudwatch や datadog のエージェントなど
    - `eksctl_courier_alb` リソースで、 Datadog や CloudWatch のメトリクスを監視しながら ALB から Target Group への重み付けを徐々に変更します
- アプリケーションのデプロイ
  - GitOps の Config Repo にマニフェストを git commit/push します
  - ArgoCD が Config Repo の更新を検知し、 ArgoCD が認識している EKS クラスタにデプロイします
  - このとき Config Repo に Flagger のマニフェスト (`Canary` リソース) があれば、クラスタ作成時にインストールしておいた Flagger がアプリケーションのカナリアデプロイを行ってくれます

# 手順

- [terraform providers のインストール](#terraform-providers-のインストール)
- `terraform apply` で [ArgoCDクラスタ一式](https://github.com/mumoshu/terraform-provider-eksctl/tree/master/examples/productionsetup-alb)のセットアップ
  - 今回はずるして terraform-provider-helmfile の代わりに 単に `helmfile` を使うかもしれません
  - Helmfile: https://github.com/mumoshu/ephemeral-eks/blob/master/helmfile.yaml
- `kubectl apply` で ArgoCD ApplicationSet を作成
- `terraform apply` で [ターゲットクラスタ一式](https://github.com/mumoshu/terraform-provider-eksctl/tree/master/examples/vpcreuse) のセットアップ
  - Helmfile: https://github.com/mumoshu/ephemeral-eks/blob/master/environments/production/podinfo/helmfile.yaml
  - ターゲットクラスタへのデプロイは `terraform apply` 中で行う方法、 `helmfile apply` で行う方法、 ArgoCD に任せる方法がある。それぞれメリデメあり
- `terraform apply` で ArgoCD クラスタ の入れ替え
- `terrafomr apply` で ターゲットクラスタ の入れ替え

## 前提条件

- terraform v0.13.0 以降

## terraform providers のインストール

Terraform v0.13.0 以降はサードパーティのプロバイダのインストールも自動化されています。

`main.tf` に以下のように必要なプロバイダの名前とバージョンを指定して、 `terraform init` すればインストールされます。

<details open>
<summary>`main.tf`</summary>

```hcl-terraform
terraform {
  required_providers {
    eksctl = {
      source = "mumoshu/eksctl"
      version = "0.13.0"
    }
    
    helmfile = {
      source = "mumoshu/helmfile"
      version = "0.10.1"
    }
  }
}
```
</details>

<details>
<summary>`terraform init`</summary>

```console
Initializing the backend...

Initializing provider plugins...
- Finding mumoshu/eksctl versions matching "0.13.0"...
- Finding mumoshu/helmfile versions matching "0.10.1"...
- Finding latest version of hashicorp/aws...
- Finding latest version of -/aws...
- Finding latest version of -/eksctl...
- Installing mumoshu/eksctl v0.13.0...
- Installed mumoshu/eksctl v0.13.0 (self-signed, key ID BE41B7B498AB7F1B)
- Installing mumoshu/helmfile v0.10.1...
- Installed mumoshu/helmfile v0.10.1 (self-signed, key ID BE41B7B498AB7F1B)
- Installing hashicorp/aws v3.18.0...
- Installed hashicorp/aws v3.18.0 (signed by HashiCorp)
- Installing -/aws v3.18.0...
- Installed -/aws v3.18.0 (signed by HashiCorp)

Partner and community providers are signed by their developers.
If you'd like to know more about provider signing, you can read about it here:
https://www.terraform.io/docs/plugins/signing.html
```
</details>

# 理解のポイント

- ArgoCD クラスタが複数のアプリケーションクラスタを管理する構成を前提とする
- ArgoCD クラスタは Terraform + Helmfileでデプロイする
  - terraform apply 一発
- アプリケーションクラスタは Terraform + Helmfileでセットアップ後、ArgoCD によって非同期でアプリがデプロイされる
- ArgoCD クラスタ自体も Blue/Green で入れ替えられるようにする
  - Blue, Green ArgoCD クラスタのどちらからも同じ IAM Role を Pod が Assume できるようにする
    - ArgoCD に管理される側のクラスタは、ArgoCD クラスタが何個いるかを気にせずに、常に単一の IAM Role に対して aws-auth でアクセス許可を行えばよい
  - ArgoCD Application は、ArgoCD に管理されるクラスタと一緒に作る。
    - ArgoCD に ApplicationSet が実装されれば解決されるかもしれない

# Q&A

Q. EKS クラスタが増えた場合に ArgoCD は自動的にそのクラスタにデプロイしてくれるのか?
A. してくれないので、 [ApplicationSet Controller](https://github.com/argoproj-labs/applicationset#example-spec) のようなものに加えて、何らかの方法で管理対象クラスタを追加する(ArgoCD の用語では「Cluster Secret の作成」する)必要がある
   ArgoCD 単体の機能だと、ArgoCD Application の Destination でデプロイ先を指示する仕様。Destination は静的なのでそこを動的にする必要がある。加えて、 ArgoCD にクラスタを追加するにはオフィシャルな方法だと「対象クラスタにアクセスできる環境から `argocd add cluster` コマンドを実行する」必要がある。

# Appendix

## ArgoCD Cluster Secret

ArgoCD は Application のデプロイ先が自クラスタ以外の場合、 Cluster Secret を必要とします。

Cluster Secret はクラスタへの接続情報が書かれた K8s Secret リソースで、通常は `argocd add cluster` コマンドを実行することで作成可能です。

その他に、スクリプト等で特定の形式の Secret リソースを書くことでも作ることができます。

以下は ArgoCD クラスタ側の Pod IAM Role を使って ターゲットクラスタに接続する場合に利用できる Cluster Secret の例です。

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <CLUSTER NAME>
  labels:
    argocd.argoproj.io/secret-type: cluster
    # Any custom annocations are accepted and available for use by ApplicationSet
    environment: production
type: Opaque
stringData:
  name: "<CLUSTER NAME>"
  server: https://<CLUSTER ID>.gr7.<REGION>.eks.amazonaws.com
  config: |
    {
      "awsAuthConfig": {
        "clusterName": "<CLUSTER NAME>"
      },
      "tlsClientConfig": {
        "insecure": false,
        "caData": "<BASE64 CA DATA>"
      }
    }
```

## ApplicationSet Controller を試す

まだ公式なコンテナイメージが存在しないので、自分でビルドする必要がある。

```console
# https://github.com/argoproj-labs/applicationset#development-instructions
$ git clone git@github.com:argoproj-labs/applicationset.git
$ cd applicationset
$ IMAGE="mumoshu/argocd-applicationset:v0.1.0" make image deploy
$ docker push mumoshu/argocd-applicationset:v0.1.0
```

この状態で、本レポジトリの `Makefile` を使って以下のように ApplicationSet Controller 込の ArgoCD クラスタを構築できる。

```
make deps apply
```

## ArgoCD クラスタからターゲットクラスタへのアクセス

ターゲットクラスタのPrivate Endpoint Accessを有効化する場合、ArgoCDクラスタ（のノード）からのK8s APIアクセスもPrivateになりSecurity Groupがきくことになるため、両クラスタ側でSecurity Groupの設定が必要。

ArgoCDクラスタのSharedNodeSecurityGroupからのアクセスを、アプリクラスタのCluster Security Group(CFN OutputではClusterSecurityGroupId=ControlPlane.ClusterSecurityGroupId)またはAddtional Security Group(CFN OutputではSecurityGroupという名前)のIngressで許可する必要がある。

前者はControl-PlaneとManaged Nodes, 後者はControl-Planeにのみ付与される。
また、前者はControl-PlaneとManaged Nodes、その他のマネージドリソースの相互通信のために利用され、後者はeksctlでは各Unmanaged Nodeからの443へのIngressを許可し、かつUnmanaged Node側からみてControl-Planeからの443(extensions api server)と1045-65535のIngress許可に使われている。

今回はArgoCDから対象クラスタのPrivate Endpoint経由でK8s APIのみアクセスできればよいので、Additional Security GroupのIngressでArgoCDクラスタのノード(に付与したSG)からの443を許可すればよい。

セキュリティグループの設定が問題なければ、ArgoCD クラスタの argocd-application-controller 上で以下のようなコマンドを実行することで、疎通確認できる。

```
$ argocd-util kubeconfig https://A3688960450F35B080D39F01CE7128E7.gr7.us-east-2.eks.amazonaws.com foo
$ KUBECONFIG=foo kubectl get no
```

# リンク集

- https://github.com/aws/eks-charts
- https://github.com/argoproj/argo-cd/issues/2347
- https://github.com/argoproj/argo-helm/tree/master/charts/argo-cd
- https://github.com/mumoshu/ephemeral-eks
- https://github.com/argoproj-labs/applicationset
