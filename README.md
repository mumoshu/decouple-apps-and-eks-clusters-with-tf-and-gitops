# Decouple applications and EKS clusters for better multi-clusters management with Terraform and GitOps

A.k.a "Keep canary-deploying applications while swapping EKS clusters with Terraform and GitOps"

本セッションでは、「EKS へのアプリケーションの円滑なデプロイ」と「EKS クラスタの円滑な入れ替え」をいかに両立させるか、とテーマにします。

## 課題感

- クラスタをどうつくるか、どうアップデートするか、というところはフォーカスしません
  - 今回は terraform と eksctl provider, helmfile provider を使っているが、これらは例として使っているだけ
  - 他のツールでも今回の考え方や方法論が適用できるはず。その考え方や方法論を参考にしてほしい
- K8s クラスタをいくつも立ち上げて、アップグレードしたり、その過程でアプリケーションを載せ替えることがあると思うので、それをいかにスムーズにするか、にフォーカスしたい

## EKS へのアプリケーションの円滑なデプロイ

CIで単体・結合・E2Eテストが行われていて、何らかのCIまたはCDによってデプロイ・リリースが(半)自動化されている方は多いのではないでしょうか？

例えば、次のようなケースです。

- CircleCI や CodePipeline+CodeBuild で Rails アプリに対して rspec によるテストを実行していて、それが通ったら手動承認ステップを通してプロダクションやステージング環境にデプロイされる
- デプロイ時には docker build, docker push によるコンテナイメージの作成とアップロードが行われる
- デプロイ時には kustomize build や helm template などによるマニフェストの生成および kubectl apply による適用、または helm install/upgrade による Helm Chart のインストールが発生する

これはもちろん素晴らしいプラクティスなのですが、サービスの規模やアプリケーションの特性によっては、デプロイ後に問題が判明した場合の切り戻しに数十秒〜数分の時間がかかってしまうことがあります。

Kubernetes Deployment でローリングアップデートを採用していて、デプロイ時の影響を最小化するために maxSurge や maxUnavailable を低めの値にしていたり、アプリケーションの起動に時間がかかる場合（例えば起動時にある程度ウォームアップが必要なアプリケーションだと、数分~数十分起動に時間がかかることもあると思います）、またはその両方…などのケースが考えられます。

こうした場合に K8s 界隈だと Open Source の Blue/Green、カナリアデプロイをサポートしてくれるツールがよく使われます。

- [Flagger](https://flagger.app/)
- [Argo Rollout](https://argoproj.github.io/argo-rollouts/)
- [Spinnaker](https://spinnaker.io/)

これらのツールはアプリケーションの前段にトラフィックの柔軟な重み付けをサポートしているプロキシサーバがあることを前提としているものも多く、以下のようなもの（や、それが提供するFront Proxy）がよく使われます。

- [Envoy](https://www.envoyproxy.io/)
- [AWS AppMesh](https://aws.amazon.com/jp/app-mesh/)
- [Istio](https://istio.io/)
- [Linkerd](https://linkerd.io/)

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

## 実装案の概要

- ALB による Target Group 間の重み付け LB + CloudWatch or Datadog でクラスタのカナリアデプロイ
- AppMesh による K8s Service 間の重み付け LB + Flagger でアプリケーションリビジョンのカナリアデプロイ

## 手順の概要

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

- [Terraform のインストール](#前提条件)
- [Terraform Providers のインストール](#terraform-providers-のインストール)
- [ArgoCD クラスタ一式の構築](#ArgoCD-クラスタ一式の構築)
- [ターゲットクラスタ一式の構築](#ターゲットクラスタ一式の構築)
- [アプリケーションの更新](#アプリケーションの更新)
- [ArgoCD クラスタの入れ替え](#ArgoCD-クラスタの入れ替え)
- [ターゲットクラスタの入れ替え](#ターゲットクラスタの入れ替え)

## 前提条件

- [terraform v0.13.0 以降](https://www.terraform.io/downloads.html)

## terraform providers のインストール

Terraform v0.13.0 以降はサードパーティのプロバイダのインストールも自動化されています。

`main.tf` に以下のように必要なプロバイダの名前とバージョンを指定して、 `terraform init` すればインストールされます。

<details>
<summary><code>main.tf</code></summary>

```hcl-terraform
terraform {
  required_providers {
    eksctl = {
      source = "mumoshu/eksctl"
      version = "0.13.0"
    }
    
    helmfile = {
      source = "mumoshu/helmfile"
      version = "0.11.0"
    }
  }
}
```
</details>

<details>
<summary><code>terraform init 実行例</code></summary>

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

## ArgoCD クラスタ一式の構築

以下のものを含む ArgoCD クラスタ一式を構築します。

- ArgoCD 用の EKS クラスタ
- 上記クラスタ上の ArgoCD や ApplicationSet Controller
- ALB等

[terraform-provider-eksctl の productionsetup-alb サンプル](https://github.com/mumoshu/terraform-provider-eksctl/tree/master/examples/productionsetup-alb)をコピーします。

<details>
<summary><code>curl -L $URL > main.tf</code></summary>

```
URL=https://raw.githubusercontent.com/mumoshu/terraform-provider-eksctl/master/examples/productionsetup-alb/testdata/01-bootstrap/main.tf

curl -L $URL > main.tf
```
</details>

<details>
<summary><code>grep -A 20 '"eksctl_cluster" "blue"' main.tf</code></summary>

```hcl-terraform
resource "eksctl_cluster" "blue" {
  eksctl_version = "0.30.0"
  name = "blue"
  region = var.region
  api_version = "eksctl.io/v1alpha5"
  version = "1.18"
  vpc_id = var.vpc_id
  kubeconfig_path = "kubeconfig"
  spec = <<EOS

nodeGroups:
  - name: ng
    instanceType: m5.large
    desiredCapacity: 1
    targetGroupARNs:
    - ${aws_lb_target_group.blue.arn}
    securityGroups:
      attachIDs:
      - ${var.security_group_id}

iam:
```
</details>

`terraform` に ArgoCD や ApplicationSet Controller のデプロイも任せますが、それは `helmfile_release_set` によって実現されています。

<details>
<summary><code>grep -A 7 '"helmfile_release_set" "blue_myapp_v1"' main.tf</code></summary>

```
resource "helmfile_release_set" "blue_myapp_v1" {
  content = file("./helmfile.yaml")
  environment = "default"
  kubeconfig = eksctl_cluster.blue.kubeconfig_path
  depends_on = [
    eksctl_cluster.blue,
  ]
}
```
</details>

一連の `terraform` コマンドを実行します。

<details>
<summary><code>terraform init</code></summary>

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

<details>
<summary><code>terraform apply</code></summary>

```
```
</details>

`kubectl` で ArgoCD クラスタ上に必要なリソースが作成されていることを確認します。

<details>
<summary><code>kubectl get deploy</code></summary>

```console
NAME                               READY   UP-TO-DATE   AVAILABLE   AGE
argocd-application-controller      1/1     1            1           12d
argocd-applicationset-controller   1/1     1            1           11d
argocd-dex-server                  1/1     1            1           12d
argocd-redis                       1/1     1            1           12d
argocd-repo-server                 1/1     1            1           12d
argocd-server                      1/1     1            1           12d
clusterset-controller              1/1     1            1           46m
tfpodinfo                          1/1     1            1           12d
```
</details>

> NOTE: `terraform` に ArgoCD 等のデプロイをまかせなかった場合は、 `helmfile` を使って [ArgoCD + ApplicationSet 等を含む `helmfile.yaml`](https://github.com/mumoshu/ephemeral-eks/blob/master/helmfile.yaml) を適用することもできます。
> 同じ `helmfile.yaml` を `helmfile` からデプロイするか、 `helmfile_release_set` リソースからデプロイするかという違いでしか無いので、結果は同じです。

## ターゲットクラスタ一式の構築

以下のものを含む ターゲットクラスタ一式を構築します。

- アプリケーション 用の EKS クラスタ
- 上記クラスタ上の Flagger、AWS AppMesh Controllerなどクラスタとライフサイクルが同じなほうが都合が良いもの
- ALB等
- アプリケーション (ただし、これは今回 ArgoCD にデプロイさせます)

[terraform-provider-eksctl の vpcreuse サンプル](https://github.com/mumoshu/terraform-provider-eksctl/tree/master/examples/vpcreuse)をコピーします。

次に、Helmfile でデプロイするものと、 ArgoCD にデプロイさせたいものを選びます。

例えば、 `cert-manager-crds` と `cert-manager` のみ `terraform apply` 中に Helmfile でまとめてデプロイし、
残りを ArgoCD でデプロイさせたい場合、 `main.tf` 側は以下のようになります。

<details>
<summary><code>main.tf</code></summary>

```
resource "helmfile_release_set" "blue_myapp_v1" {
  content = file("./helmfile.yaml")
  environment = "default"
  kubeconfig = eksctl_cluster.blue.kubeconfig_path
  values = {
    namespace = "podinfo"
  }
  // helmfile -l name=cert-manager -l name=cert-manager-crds template 相当
  selectors = [
    "name=cert-manager-crds",
    "name=cert-manager",
  ]
  depends_on = [
    eksctl_cluster.blue,
  ]
}
```
</details>

また、 ArgoCD にデプロイさせるものを絞り込むため、ArgoCD クラスタ用 [helmfile.yaml](helmfile.yaml) 内 Config Management Plugin の `helmfile` コマンドの引数に `-l name!=cert-manager,name!=cert-manager-crds` を追加します。

<details>
<summary><code>helmfile.yaml - configManagementPlugins</code></summary>

```
configManagementPlugins: |
- name: helmfile
  init:
    command: ["/bin/sh", "-c"]
    # ARGOCD_APP_NAMESPACE is one of the standard envvars
    # See https://argoproj.github.io/argo-cd/user-guide/build-environment/
    args: ["helmfile --state-values-set ns=$ARGOCD_APP_NAMESPACE -f helmfile.yaml -l name!=cert-manager,name!=cert-manager-crds template --include-crds | sed -e '1,/---/d' | sed -e '/WARNING: This chart is deprecated/d' | sed -e 's|apiregistration.k8s.io/v1beta1|apiregistration.k8s.io/v1|g' > manifests.yaml"]
  generate:
    command: ["/bin/sh", "-c"]
    args: ["cat manifests.yaml"]
```
</details>

> アプリも含めすべてを `terraform apply` でデプロイしてしまいたい場合は、 `helmfile_release_set` の `selectors` と、 Config Management Plugin の `-l` フラグを省略すればOKです。

`terraform apply` を実行します。

<details>
</details>

ArgoCD クラスタ上の ClusterSet Controller がターゲットクラスタを登録します。

<details>
<summary><code>kubectl logs deploy/controller-manager -c manager -f</code></summary>

```console
...
2020/11/27 05:15:06 Using in-cluster Kubernetes API client
2020/11/27 05:15:06 Computing desired cluster secrets from EKS clusters...
2020/11/27 05:15:06 Calling EKS ListClusters...
2020/11/27 05:15:06 Found 3 clusters.
2020/11/27 05:15:06 Checking cluster blue...
2020/11/27 05:15:06 Cluster blue with tags map[] did not match selector map[foo:bar]
2020/11/27 05:15:06 Checking cluster green...
2020/11/27 05:15:06 Cluster green with tags map[] did not match selector map[foo:bar]
2020/11/27 05:15:06 Checking cluster ${CLUSTER_NAME}...
Cluster secert "${CLUSTER_NAME}" created successfully
2020/11/27 05:15:06 Using in-cluster Kubernetes API client
2020/11/27 05:15:06 Computing desired cluster secrets from EKS clusters...
2020/11/27 05:15:06 Calling EKS ListClusters...
2020/11/27 05:15:07 Found 3 clusters.
2020/11/27 05:15:07 Checking cluster blue...
2020/11/27 05:15:07 Cluster blue with tags map[] did not match selector map[foo:bar]
2020/11/27 05:15:07 Checking cluster green...
2020/11/27 05:15:07 Cluster green with tags map[] did not match selector map[foo:bar]
2020/11/27 05:15:07 Checking cluster ${CLUSTER_NAME}...
2020-11-27T05:15:07.406Z	DEBUG	controller	Successfully Reconciled	{"reconcilerGroup": "clusterset.mumo.co", "reconcilerKind": "ClusterSet", "controller": "clusterset", "name": "myclusterset1", "namespace": "default"}
2020-11-27T05:15:07.406Z	DEBUG	controller-runtime.manager.events	Normal	{"object": {"kind":"ClusterSet","namespace":"default","name":"myclusterset1","uid":"dd9eef73-f781-4d22-a562-6d4363ebf798","apiVersion":"clusterset.mumo.co/v1alpha1","resourceVersion":"3161147"}, "reason": "SyncFinished", "message": "Sync finished on 'myclusterset1'"}
...
```
</details>

<details>
<summary><code>kubectl neat get secret -o yaml $CLUSTER_NAME</code></summary>

```console
apiVersion: v1
data:
  config: <BASE64 ENCODED JSON CONFIG>
  name: <BASE64 ENCODED CLUSTER NAME>
  server: <BASE64 ENCODED HTTPS URL TO K8s API>
kind: Secret
metadata:
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: prod
  name: $CLUSTER_NAME
  namespace: default
type: Opaque
```
</details>

ArgoCD クラスタ上の ApplicationSet Controller が新しいターゲットクラスタ用の Application リソースを作成します。

<details>
<summary><code>kubectl neat get application -o yaml ${CLUSTER_NAME}-podinfo</code></summary>

```console
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  labels:
    environment: prod
  name: ${CLUSTER_NAME}-podinfo
  namespace: default
spec:
  destination:
    name: ${CLUSTER_NAME}
    namespace: default
  source:
    path: environments/production/podinfo
    plugin:
      name: helmfile
    repoURL: https://github.com/mumoshu/decouple-apps-and-eks-clusters-with-tf-and-gitops.git
    targetRevision: HEAD
```
</details>

ArgoCD クラスタ上の Application Controller がターゲットクラスタにアプリケーションをデプロイします。

<details>
<summary><code>kubectl logs deploy/argocd-application-controller -f</code></summary>

```
time="2020-11-27T05:15:13Z" level=info msg="Normalized app spec: {\"spec\":{\"project\":\"default\"}}" application=${CLUSTER_NAME}-podinfo
time="2020-11-27T05:15:13Z" level=info msg="Initiated automated sync to '1d6e2f4077e5a714bee4918312437d5b2ed153dc'" application=${CLUSTER_NAME}-podinfo dest-namespace=default dest-server="https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com" reason=OperationStarted type=Normal
time="2020-11-27T05:15:13Z" level=info msg="updated '${CLUSTER_NAME}-podinfo' operation (phase: Running)"
time="2020-11-27T05:15:13Z" level=info msg="Initialized new operation: {&SyncOperation{Revision:1d6e2f4077e5a714bee4918312437d5b2ed153dc,Prune:false,DryRun:false,SyncStrategy:nil,Resources:[]SyncOperationResource{},Source:nil,Manifests:[],SyncOptions:[],} { true} [] {5 nil}}" application=${CLUSTER_NAME}-podinfo
time="2020-11-27T05:15:13Z" level=info msg="Ignore status for CustomResourceDefinitions"
time="2020-11-27T05:15:13Z" level=info msg="Comparing app state (cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default)" application=${CLUSTER_NAME}-podinfo
time="2020-11-27T05:15:13Z" level=info msg="Initiated automated sync to '1d6e2f4077e5a714bee4918312437d5b2ed153dc'" application=${CLUSTER_NAME}-podinfo
time="2020-11-27T05:15:13Z" level=info msg="Updated sync status:  -> OutOfSync" application=${CLUSTER_NAME}-podinfo dest-namespace=default dest-server= reason=ResourceUpdated type=Normal
time="2020-11-27T05:15:13Z" level=info msg="Updated health status:  -> Missing" application=${CLUSTER_NAME}-podinfo dest-namespace=default dest-server= reason=ResourceUpdated type=Normal
time="2020-11-27T05:15:13Z" level=info msg="getRepoObjs stats" application=${CLUSTER_NAME}-podinfo build_options_ms=0 helm_ms=0 plugins_ms=0 repo_ms=0 time_ms=33 unmarshal_ms=33 version_ms=0
time="2020-11-27T05:15:13Z" level=info msg="Update successful" application=${CLUSTER_NAME}-podinfo
time="2020-11-27T05:15:13Z" level=info msg="Reconciliation completed" application=${CLUSTER_NAME}-podinfo dedup_ms=0 dest-name=${CLUSTER_NAME} dest-namespace=default dest-server= diff_ms=125 fields.level=2 git_ms=5982 health_ms=0 live_ms=0 settings_ms=0 sync_ms=0 time_ms=6251
time="2020-11-27T05:15:13Z" level=info msg="Ignore status for CustomResourceDefinitions"
time="2020-11-27T05:15:13Z" level=info msg=syncing application=${CLUSTER_NAME}-podinfo skipHooks=false started=false syncId=00001-IktCv
time="2020-11-27T05:15:13Z" level=info msg=tasks application=${CLUSTER_NAME}-podinfo syncId=00001-IktCv tasks="[Sync/0 resource apiextensions.k8s.io/CustomResourceDefinition:default/certificaterequests.cert-manager.io nil->obj (,,), Sync/0 resource apiextensions.k8s.io/CustomResourceDefinition:default/certificates.cert-manager.io nil->obj (,,), Sync/0 resource apiextensions.k8s.io/CustomResourceDefinition:default/challenges.acme.cert-manager.io nil->obj (,,), Sync/0 resource apiextensions.k8s.io/CustomResourceDefinition:default/clusterissuers.cert-manager.io nil->obj (,,), Sync/0 resource apiextensions.k8s.io/CustomResourceDefinition:default/issuers.cert-manager.io nil->obj (,,), Sync/0 resource apiextensions.k8s.io/CustomResourceDefinition:default/orders.acme.cert-manager.io nil->obj (,,)]"
time="2020-11-27T05:15:13Z" level=info msg="Applying resource CustomResourceDefinition/certificaterequests.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:13Z" level=info msg="Applying resource CustomResourceDefinition/certificates.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:13Z" level=info msg="Applying resource CustomResourceDefinition/clusterissuers.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:13Z" level=info msg="Applying resource CustomResourceDefinition/issuers.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:13Z" level=info msg="Applying resource CustomResourceDefinition/challenges.acme.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:13Z" level=info msg="Applying resource CustomResourceDefinition/orders.acme.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:14Z" level=info msg="Updating operation state. phase: Running -> Running, message: '' -> 'one or more tasks are running'" application=${CLUSTER_NAME}-podinfo syncId=00001-IktCv
time="2020-11-27T05:15:14Z" level=info msg="Applying resource CustomResourceDefinition/clusterissuers.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:14Z" level=info msg="Applying resource CustomResourceDefinition/certificaterequests.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:14Z" level=info msg="Applying resource CustomResourceDefinition/issuers.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:14Z" level=info msg="Applying resource CustomResourceDefinition/certificates.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:14Z" level=info msg="Applying resource CustomResourceDefinition/challenges.acme.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:14Z" level=info msg="Applying resource CustomResourceDefinition/orders.acme.cert-manager.io in cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default"
time="2020-11-27T05:15:14Z" level=info msg="adding resource result, status: 'Synced', phase: 'Running', message: 'customresourcedefinition.apiextensions.k8s.io/certificates.cert-manager.io created'" application=${CLUSTER_NAME}-podinfo kind=CustomResourceDefinition name=certificates.cert-manager.io namespace=default phase=Sync syncId=00001-IktCv
time="2020-11-27T05:15:14Z" level=warning msg="Partial success when performing preferred resource discovery: unable to retrieve the complete list of server APIs: acme.cert-manager.io/v1: the server could not find the requested resource, acme.cert-manager.io/v1alpha2: the server could not find the requested resource, acme.cert-manager.io/v1alpha3: the server could not find the requested resource, acme.cert-manager.io/v1beta1: the server could not find the requested resource, cert-manager.io/v1: the server could not find the requested resource, cert-manager.io/v1alpha2: the server could not find the requested resource, cert-manager.io/v1alpha3: the server could not find the requested resource, cert-manager.io/v1beta1: the server could not find the requested resource"
time="2020-11-27T05:15:15Z" level=info msg="adding resource result, status: 'Synced', phase: 'Running', message: 'customresourcedefinition.apiextensions.k8s.io/orders.acme.cert-manager.io created'" application=${CLUSTER_NAME}-podinfo kind=CustomResourceDefinition name=orders.acme.cert-manager.io namespace=default phase=Sync syncId=00001-IktCv
time="2020-11-27T05:15:15Z" level=info msg="adding resource result, status: 'Synced', phase: 'Running', message: 'customresourcedefinition.apiextensions.k8s.io/certificaterequests.cert-manager.io created'" application=${CLUSTER_NAME}-podinfo kind=CustomResourceDefinition name=certificaterequests.cert-manager.io namespace=default phase=Sync syncId=00001-IktCv
time="2020-11-27T05:15:16Z" level=info msg="adding resource result, status: 'Synced', phase: 'Running', message: 'customresourcedefinition.apiextensions.k8s.io/issuers.cert-manager.io created'" application=${CLUSTER_NAME}-podinfo kind=CustomResourceDefinition name=issuers.cert-manager.io namespace=default phase=Sync syncId=00001-IktCv
time="2020-11-27T05:15:17Z" level=info msg="adding resource result, status: 'Synced', phase: 'Running', message: 'customresourcedefinition.apiextensions.k8s.io/challenges.acme.cert-manager.io created'" application=${CLUSTER_NAME}-podinfo kind=CustomResourceDefinition name=challenges.acme.cert-manager.io namespace=default phase=Sync syncId=00001-IktCv
time="2020-11-27T05:15:18Z" level=info msg="adding resource result, status: 'Synced', phase: 'Running', message: 'customresourcedefinition.apiextensions.k8s.io/clusterissuers.cert-manager.io created'" application=${CLUSTER_NAME}-podinfo kind=CustomResourceDefinition name=clusterissuers.cert-manager.io namespace=default phase=Sync syncId=00001-IktCv
time="2020-11-27T05:15:18Z" level=info msg="Updating operation state. phase: Running -> Succeeded, message: 'one or more tasks are running' -> 'successfully synced (all tasks run)'" application=${CLUSTER_NAME}-podinfo syncId=00001-IktCv
time="2020-11-27T05:15:18Z" level=info msg="sync/terminate complete" application=${CLUSTER_NAME}-podinfo duration=4.742508828s syncId=00001-IktCv
time="2020-11-27T05:15:18Z" level=info msg="updated '${CLUSTER_NAME}-podinfo' operation (phase: Succeeded)"
time="2020-11-27T05:15:18Z" level=info msg="Sync operation to 1d6e2f4077e5a714bee4918312437d5b2ed153dc succeeded" application=${CLUSTER_NAME}-podinfo dest-namespace=default dest-server="https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com" reason=OperationCompleted type=Normal
time="2020-11-27T05:15:18Z" level=info msg="Refreshing app status (controller refresh requested), level (2)" application=${CLUSTER_NAME}-podinfo
time="2020-11-27T05:15:18Z" level=info msg="Ignore status for CustomResourceDefinitions"
time="2020-11-27T05:15:18Z" level=info msg="Comparing app state (cluster: https://${CLUSTER_ID}.sk1.us-east-2.eks.amazonaws.com, namespace: default)" application=${CLUSTER_NAME}-podinfo
time="2020-11-27T05:15:18Z" level=info msg="getRepoObjs stats" application=${CLUSTER_NAME}-podinfo build_options_ms=0 helm_ms=0 plugins_ms=0 repo_ms=0 time_ms=110 unmarshal_ms=110 version_ms=0
time="2020-11-27T05:15:18Z" level=info msg="Normalized app spec: {\"spec\":{\"project\":\"default\"}}" application=${CLUSTER_NAME}-podinfo
time="2020-11-27T05:15:19Z" level=info msg="Skipping auto-sync: application status is Synced" application=${CLUSTER_NAME}-podinfo
time="2020-11-27T05:15:19Z" level=info msg="Updated sync status: OutOfSync -> Synced" application=${CLUSTER_NAME}-podinfo dest-namespace=default dest-server= reason=ResourceUpdated type=Normal
time="2020-11-27T05:15:19Z" level=info msg="Updated health status: Missing -> Healthy" application=${CLUSTER_NAME}-podinfo dest-namespace=default dest-server= reason=ResourceUpdated type=Normal
time="2020-11-27T05:15:19Z" level=info msg="Update successful" application=${CLUSTER_NAME}-podinfo
time="2020-11-27T05:15:19Z" level=info msg="Reconciliation completed" application=${CLUSTER_NAME}-podinfo dedup_ms=0 dest-name=${CLUSTER_NAME} dest-namespace=default dest-server= diff_ms=593 fields.level=2 git_ms=111 health_ms=0 live_ms=47 settings_ms=0 sync_ms=0 time_ms=1004
```
</details>

Application(Set) リソースに定義通り、ターゲットクラスタ上にK8s リソース一式が作成されます。

<details>
<summary><code>kubectl get ns</code></summary>

```
NAME              STATUS   AGE
appmesh-system    Active   2m
cert-manager      Active   118s
default           Active   9d
kube-node-lease   Active   9d
kube-public       Active   9d
kube-system       Active   9d
podinfo           Active   57s
```
</details>

<details>
<summary><code>kubectl get -n appmesh-system deploy</code></summary>

```
NAME                 READY   UP-TO-DATE   AVAILABLE   AGE
appmesh-controller   1/1     1            1           63s
appmesh-grafana      1/1     1            1           93s
appmesh-prometheus   1/1     1            1           94s
flagger              1/1     1            1           92s
```
</details>

<details>
<summary><code>kubectl get deploy -n cert-manager</code></summary>

```
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
cert-manager              1/1     1            1           5m16s
cert-manager-cainjector   1/1     1            1           5m16s
cert-manager-webhook      1/1     1            1           5m16s
```
</details>

<details>
<summary><code>kubectl get -n podinfo deploy</code></summary>

```
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
backend                   1/1     1            1           3m40s
backend-loadtester        1/1     1            1           3m42s
backend-primary           2/2     2            2           3m36s
frontend                  1/1     1            1           3m40s
frontend-loadtester       1/1     1            1           3m40s
frontend-primary          2/2     2            2           3m36s
gateway-appmesh-gateway   1/1     1            1           3m40s
```
</details>

## アプリケーションのデプロイ

`values.yaml` を書き換えて、デプロイ対象のコンテナイメージタグ等を変更します。

```
$EDITOR environments/production/podinfo/frontend.values.yaml
```

Config レポジトリに commit/push します。

> よくある GitOps の実装だと、 Config レポジトリの内容は K8s マニフェストや kustomization だと思います。
> 今回は helmfile の設定を Config レポジトリの内容にしているので、作業としてはこれだけでOKです。

```
git add environments/production/podinfo/*.values.yaml
git commit -m 'Update values'
git push
```

これで、稼働している全 ArgoCD クラスタが Config レポジトリの変更を自動的に検知して、アプリケーションを全クラスタにデプロイしてくれます。

## ArgoCD クラスタの入れ替え

`eksctl_cluster` リソースを追加し、`eksctl_courier_alb` の destination を書き換え、新しい `eksctl_cluster` （につながる Target Group) の重みが最終的に 100% となるようにします。

<details>
<summary><code>main.tf 差分例</code></summary>

```diff
--- temp	2020-11-27 15:45:48.000000000 +0900
+++ temp2	2020-11-27 15:46:48.000000000 +0900
@@ -11,16 +11,63 @@
   destination {
     target_group_arn = aws_lb_target_group.blue.arn
 
-    weight = 100
+    weight = 0
   }
 
   destination {
     target_group_arn = aws_lb_target_group.green.arn
-    weight = 0
+    weight = 100
   }
 
   depends_on = [
     eksctl_cluster.green,
     helmfile_release_set.green_myapp_v1
   ]
-}
\ No newline at end of file
+}
+
+resource "helmfile_release_set" "green_myapp_v1" {
+  content = file("./helmfile.yaml")
+  environment = "default"
+  kubeconfig = eksctl_cluster.green.kubeconfig_path
+  depends_on = [
+    eksctl_cluster.green,
+  ]
+}
+
+resource "eksctl_cluster" "green" {
+  eksctl_version = "0.30.0"
+  name = "green"
+  region = var.region
+  api_version = "eksctl.io/v1alpha5"
+  version = "1.18"
+  vpc_id = var.vpc_id
+  kubeconfig_path = "kubeconfig.green"
+  spec = <<EOS
+
+nodeGroups:
+  - name: ng
+    instanceType: m5.large
+    desiredCapacity: 1
+    targetGroupARNs:
+    - ${aws_lb_target_group.green.arn}
+    securityGroups:
+      attachIDs:
+      - ${var.security_group_id}
+
+iam:
+  withOIDC: true
+  serviceAccounts: []
+
+vpc:
+  cidr: "${var.vpc_cidr_block}"       # (optional, must match CIDR used by the given VPC)
+  subnets:
+    %{~ for group in keys(var.vpc_subnet_groups) }
+    ${group}:
+      %{~ for subnet in var.vpc_subnet_groups[group] }
+      ${subnet.az}:
+        id: "${subnet.id}"
+        cidr: "${subnet.cidr}"
+      %{ endfor ~}
+    %{ endfor ~}
+EOS
+}
```
</details>

`terraform apply` を実行すると、 EKS クラスタの作成後、 Helmfile によるデプロイが行われ、その後徐々に ALB の向き先が新しい ArgoCD クラスタに切り替わっていきます。

> 注: 一時的にArgoCD クラスタが2つになり、2つの ArgoCD がターゲットクラスタにデプロイを行うようになります。
>
> クラスタによってデプロイ内容が変わるようなケース（？）がもしあれば、古い方の ArgoCD にある Application の auto-sync を止める…などの工夫が必要になります。

## ターゲットクラスタの入れ替え

`eksctl_cluster` リソースを追加し、 `eksctl_courier_alb` の destination を書き換え、新しい `eksctl_cluster` （につながる Target Group) の重みが最終的に 100% となるようにします。

<details>
<summary><code>main.tf 差分例</code></summary>

```diff
--- temp	2020-11-27 15:45:48.000000000 +0900
+++ temp2	2020-11-27 15:46:48.000000000 +0900
@@ -11,16 +11,63 @@
   destination {
     target_group_arn = aws_lb_target_group.blue.arn
 
-    weight = 100
+    weight = 0
   }
 
   destination {
     target_group_arn = aws_lb_target_group.green.arn
-    weight = 0
+    weight = 100
   }
 
   depends_on = [
     eksctl_cluster.green,
     helmfile_release_set.green_myapp_v1
   ]
-}
\ No newline at end of file
+}
+
+resource "helmfile_release_set" "green_myapp_v1" {
+  content = file("./helmfile.yaml")
+  environment = "default"
+  kubeconfig = eksctl_cluster.green.kubeconfig_path
+  depends_on = [
+    eksctl_cluster.green,
+  ]
+}
+
+resource "eksctl_cluster" "green" {
+  eksctl_version = "0.30.0"
+  name = "green"
+  region = var.region
+  api_version = "eksctl.io/v1alpha5"
+  version = "1.18"
+  vpc_id = var.vpc_id
+  kubeconfig_path = "kubeconfig.green"
+  spec = <<EOS
+
+nodeGroups:
+  - name: ng
+    instanceType: m5.large
+    desiredCapacity: 1
+    targetGroupARNs:
+    - ${aws_lb_target_group.green.arn}
+    securityGroups:
+      attachIDs:
+      - ${var.security_group_id}
+
+iam:
+  withOIDC: true
+  serviceAccounts: []
+
+vpc:
+  cidr: "${var.vpc_cidr_block}"       # (optional, must match CIDR used by the given VPC)
+  subnets:
+    %{~ for group in keys(var.vpc_subnet_groups) }
+    ${group}:
+      %{~ for subnet in var.vpc_subnet_groups[group] }
+      ${subnet.az}:
+        id: "${subnet.id}"
+        cidr: "${subnet.cidr}"
+      %{ endfor ~}
+    %{ endfor ~}
+EOS
+}
```
</details>

`terraform apply` を実行すると、EKS クラスタの作成と Helmfile によるデプロイが完了後、徐々に ALB の向き先が変わっていきます。

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

Q. こんな課題感をもつきっかけはなんだったか?

A. アプリケーションはカナリアデプロイで気軽に更新できるようになってきたが、クラスタが塩漬けになりがち。クラスタも気軽に更新できないか？アプリと同様にクラスタ自体もカナリアデプロイできないか？アプリとクラスタを同時並行で独立してカナリアデプロイできたら最高なのにな、と思ったことがきっかけ。

Q. EKS クラスタが増えた場合に ArgoCD は自動的にそのクラスタにデプロイしてくれるのか?

A. 通常はしてくれないので、工夫が必要です。

具体的には、何らかの方法で ArgoCD Application (デプロイ先とデプロイ内容の定義を含む) と Cluster Secret (デプロイ先クラスタの接続情報が含まれる K8s Secret) を作成する必要があります。

> ArgoCD 単体の機能だと、ArgoCD Application の Destination でデプロイ先を指示する仕様。Destination は静的なのでそこを動的にする必要がある。加えて、 ArgoCD にクラスタを追加する (= Cluster Secret を作成する) にはオフィシャルな方法だと「対象クラスタにアクセスできる環境から `argocd add cluster` コマンドを実行する」ことになります。

そこで今回は、「Cluster Secret が増えるたびに Application を自動作成」するために [ApplicationSet Controller](https://github.com/argoproj-labs/applicationset#example-spec) 、「EKS クラスタが増えるたびに Cluster Secret を自動作成」するために [ClusterSet Controller](https://github.com/mumoshu/argocd-clusterset) を利用しました。

# ゴール

- 何がどう動いているかイメージがつかめる
- Next Action
  - レポジトリ紹介
  - aws-cdk版、pulumi版、独自スクリプト・コマンド版だれか作って欲しい
  - 社内勉強会とかでこの内容をそのまま使ってもらえる状態が理想なので、fork, pull requestしてほしい

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

## ArgoCD でデプロイ失敗したとき

`kubectl describe application` してみると、 Status に直接原因が書かれている。

<details>

```
Status:
  Conditions:
    Last Transition Time:  2020-11-28T04:36:37Z
    Message:               Failed sync attempt to 8253234632f29dfc2d07c390e357238ef83f0d3f: one or more objects failed to apply (dry run) (retried 5 times).
    Type:                  SyncError
  Health:
    Status:  Missing
  Operation State:
    Finished At:  2020-11-28T04:36:36Z
    Message:      one or more objects failed to apply (dry run) (retried 5 times).
    Operation:
      Initiated By:
        Automated:  true
      Retry:
        Limit:  5
      Sync:
        Prune:     true
        Revision:  8253234632f29dfc2d07c390e357238ef83f0d3f
    Phase:         Failed
    Retry Count:   5
    Sync Result:
      Resources:
      ...
```
</details>

`Sync Result > Resources` 以下にリソース別の情報 - エラーならその内容 - が書かれている。

例えば、以下の例は AppMesh の Admission Webhook Server が稼働する前に Apply しようとしたことによる一時的なエラー（リトライでそのうち成功するはず）

<details>

```
Group:       appmesh.k8s.aws
Hook Phase:  Failed
Kind:        Mesh
Message:     Internal error occurred: failed calling webhook "mmesh.appmesh.k8s.aws": Post https://appmesh-controller-webhook-service.appmesh-system.svc:443/mutate-appmesh-k8s-aws-v1beta2-mesh?timeout=30s: no endpoints available for service "appmesh-controller-webhook-service"
Name:        global
Namespace:   podinfo
Status:      SyncFailed
Sync Phase:  Sync
Version:     v1beta2
```
</details>

以下は Config Management Plugin で生成したマニフェストに余分な文字列が含まれていて、 YAML or K8s Resource として Invalid な場合のエラー（こちらはユーザエラーなのでマニフェストを修正するまで成功しない）

<details>

```
Group:       apiextensions.k8s.io
Hook Phase:  Failed
Kind:        CustomResourceDefinition
Message:     error validating data: ValidationError(CustomResourceDefinition): unknown field "WARNING" in io.k8s.apiextensions-apiserver.pkg.apis.apiextensions.v1.CustomResourceDefinition
Name:        orders.acme.cert-manager.io
Namespace:   podinfo
Status:      SyncFailed
Sync Phase:  Sync
Version:     v1
```
</details>

Config Management Plugin を利用している場合、 環境差異によって想定通りのマニフェストが生成されてないことによるエラーはよくある。

その場合、 argocd-repo-server 内に Config Repository の clone が存在するので、そこで Config Management Plugin と同等のコマンドを実行してみるとデバッグできる。

<details>

```
$ kubectl exec -it argocd-repo-server-85bf8d77fb-4sbrq -- bash

$ cd /tmp/https\:__githubcom_mumoshu_decouple-apps-and-eks-clusters-with-tf-and-gitops/

$ ls -l
-rw-r--r-- 1 argocd argocd  1667 Nov 27 06:28 Makefile
-rw-r--r-- 1 argocd argocd 43594 Nov 27 06:52 README.md
drwxr-xr-x 2 argocd argocd    22 Nov 27 05:15 cert-manager-crds
drwxr-xr-x 4 argocd argocd    58 Nov 27 05:15 charts
drwxr-xr-x 3 argocd argocd    24 Nov 27 05:15 environments
drwxr-xr-x 3 argocd argocd    45 Nov 27 05:15 forks
-rw-r--r-- 1 argocd argocd  5900 Nov 28 04:44 helmfile.yaml
-rw-r--r-- 1 argocd argocd   330 Nov 27 05:15 tester.yaml

$ cd environments/production/podinfo/

$ helmfile template --include-crds > manifests.yaml
```
</details>

# リンク集

- ApplictionSet Controller のソース https://github.com/argoproj-labs/applicationset
- ClusterSet Controller のソース https://github.com/mumoshu/argocd-clusterset
- ArgoCD Helm Chart https://github.com/argoproj/argo-helm/tree/master/charts/argo-cd
- EKS Charts https://github.com/aws/eks-charts
- "trouble using --aws-role-arn option when adding EKS cluster with argocd CLI" https://github.com/argoproj/argo-cd/issues/2347
- [terraform-provider-eksctl](https://github.com/mumoshu/terraform-provider-eksctl/)
- [terraform-provider-helmfile](https://github.com/mumoshu/terraform-provider-helmfile/)
- [helmfile](https://github.com/roboll/helmfile/)
