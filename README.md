# Calico Cloud Demo on an EKS Cluster

In this demo, you will work with AWS EKS and Calico Cloud to learn how to design and deploy best practices to secure your Kubernetes environment. This 60-minute hands-on lab will guide you from building an EKS cluster, creating a Calico Cloud trial account and registering your EKS cluster to Calico Cloud for configuring security policies to protect your workloads. This sample environment is designed to help implement:

- Security Policies for pods and namespaces.
  - Policy tiers
  - Security Policies
  - Security Policy Recommender
  - DNS Policies
  - Ingress Policies
- Infrastructure as a Code and Calico Cloud.
- Customizing deployed policies.
- Best Practices for EKS cluster.

---

### Create your EKS cluster

Calico can be used as a CNI, or you can decide to use AWS VPC networking and have Calico only as plugin for the security policies. 

We will use the second approach during the workshop. Below an example on how to create a two nodes cluster with an smaller footprint, but feel free to create your EKS cluster with the parameters you prefer. Do not forget to include the region if different than the default on your account.

```
eksctl create cluster --name <CLUSTER_NAME> --version 1.21 --node-type m5.xlarge
```

### Connect your cluster to Calico Cloud

Subscribe to the free Calico Cloud trial on the link below:

https://www.calicocloud.io/home

Once you are able to login to Calico Cloud UI, go to the "Managed clusters" section, and click on the "Connect Cluster" button, then leave "Amazon EKS" selected, and give a name to your cluster, and click "Next". Read the cluster requirements in teh next section, and click "Next". Finally, copy the kubectl command you must run in order to connect your cluster to the management cluster for your Calico Cloud instance.

![managed-clusters](https://user-images.githubusercontent.com/104035488/206290672-8af9c13f-314a-4752-8cb8-ff1b892484d6.png)

---

## Enviroment Preparation

### Decrease the time to collect flow logs

By default, flow logs are collected every 5 minutes. We will decrease that time to 15 seconds, which will increase the amount of information we must store, and while that is not recommended for production environments, it will help to speed up the time in which events are seen within Calico observability features.

```bash
kubectl patch felixconfiguration default -p '{"spec":{"flowLogsFlushInterval":"15s"}}'
kubectl patch felixconfiguration default -p '{"spec":{"dnsLogsFlushInterval":"15s"}}'
kubectl patch felixconfiguration default -p '{"spec":{"flowLogsFileAggregationKindForAllowed":1}}'
kubectl patch felixconfiguration default -p '{"spec":{"flowLogsFileAggregationKindForDenied":0}}'
kubectl patch felixconfiguration default -p '{"spec":{"dnsLogsFileAggregationKind":0}}'
```

Configure Felix to collect TCP stats - this uses eBPF TC program and requires miniumum Kernel version of v5.3.0/v4.18.0-193. Further documentation.

```bash
kubectl patch felixconfiguration default -p '{"spec":{"flowLogsCollectTcpStats":true}}'
```

### Install demo applications

- Deploy demo applications.

  Deploy the dev app stack

  ```bash
  kubectl apply -f https://raw.githubusercontent.com/regismartins/cc-aks-security-compliance-workshop/main/manifests/dev-app-manifest.yaml
  ```
  
  Deploy the Online Boutique app stack

  ```bash
  kubectl apply -f https://raw.githubusercontent.com/regismartins/cc-aks-security-compliance-workshop/main/manifests/kubernetes-manifests.yaml
  ```

---

## Access controls

Calico provides methods to enable fine-grained access controls between your microservices and external databases, cloud services, APIs, and other applications that are protected behind a firewall. You can enforce controls from within the cluster using DNS egress policies, from a firewall outside the cluster using the egress gateway. Controls are applied on a fine-grained, per-pod basis.

## Service Graph and Flow Visualizer

Connect to Calico Cloud GUI. From the menu select `Service Graph > Default`. Explore the options.

![service_graph](https://user-images.githubusercontent.com/104035488/192303379-efb43faa-1e71-41f2-9c54-c9b7f0538b34.gif)

Connect to Calico Cloud GUI. From the menu select `Service Graph > Flow Visualizations`. Explore the options.

![flow-visualization](https://user-images.githubusercontent.com/104035488/192358472-112c832f-2fd7-4294-b8cc-fec166a9b11e.gif)


## Security Policy Tier structure

Tiers are a hierarchical construct used to group policies and enforce higher precedence policies that cannot be circumvented by other    teams. 

All Calico and Kubernetes security policies reside in tiers. You can start “thinking in tiers” by grouping your teams and types of policies within each group. The command below will create three tiers (quarantine, platform, and security):

```yaml
kubectl apply -f - <<-EOF   
apiVersion: projectcalico.org/v3
kind: Tier
metadata:
  name: quarantine
spec:
  order: 200
---
apiVersion: projectcalico.org/v3
kind: Tier
metadata:
  name: platform
spec:
  order: 300
---
apiVersion: projectcalico.org/v3
kind: Tier
metadata:
  name: security
spec:
  order: 400
```

For normal policy processing (without apply-on-forward, pre-DNAT, and do-not-track), if no policies within a tier apply to endpoints, the tier is skipped, and the tier’s implicit deny behavior is not executed.

For example, if policy D in Tier 2 includes a Pass action rule, but no policy matches endpoints in Tier 3, Tier 3 is skipped, including the end of tier deny. The first policy with a matching endpoint is in Tier 4, policy J.

![endpoint-match](./img/endpoint-match.svg)
--

## Security Policies

A global default deny policy ensures that unwanted traffic (ingress and egress) is denied by default. Pods without policy (or incorrect policy) are not allowed traffic until appropriate network policy is defined. Although the staging policy tool will help you find incorrect and missing policy, a global deny helps mitigate against other lateral malicious attacks.

By default, all traffic is allowed between the pods in a cluster. First, let's test connectivity between application components and across application stacks. All of these tests should succeed as there are no policies in place.

Install curl in the loadgenerator for these tests.

```bash
kubectl exec -it $(kubectl get po -l app=loadgenerator -ojsonpath='{.items[0].metadata.name}') -c main -- sh -c 'apt-get update && apt install curl -y'
```

a. Test connectivity between workloads within each namespace, use dev and default namespaces as example

   ```bash
   # test connectivity within dev namespace, the expected result is "HTTP/1.1 200 OK" 
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -sI http://nginx-svc 2>/dev/null | grep -i http'
   ```

   ```bash
   # test connectivity within default namespace in 8080 port
   kubectl exec -it $(kubectl -n default get po -l app=frontend -ojsonpath='{.items[0].metadata.name}') \
   -c server -- sh -c 'nc -zv recommendationservice 8080'
   ```

b. Test connectivity across namespaces dev/centos and default/frontend.

   ```bash
   # test connectivity from dev namespace to default namespace, the expected result is "HTTP/1.1 200 OK"
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -sI http://frontend.default 2>/dev/null | grep -i http'
   ```

c. Test connectivity from each namespace dev and default to the Internet.

   ```bash
   # test connectivity from dev namespace to the Internet, the expected result is "HTTP/1.1 200 OK"
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -sI http://www.google.com 2>/dev/null | grep -i http'
   ```

   ```bash
   # test connectivity from default namespace to the Internet, the expected result is "HTTP/1.1 200 OK"
   kubectl exec -it $(kubectl get po -l app=loadgenerator -ojsonpath='{.items[0].metadata.name}') \
   -c main -- sh -c 'curl -m3 -sI http://www.google.com 2>/dev/null | grep -i http'
   ```

We recommend that you create a global default deny policy after you complete writing policy for the traffic that you want to allow. Use the stage policy feature to get your allowed traffic working as expected, then lock down the cluster to block unwanted traffic.

1. Create a staged global default deny policy. It will shows all the traffic that would be blocked if it were converted into a deny.

   ```yaml
   kubectl apply -f - <<-EOF
   apiVersion: projectcalico.org/v3
   kind: StagedGlobalNetworkPolicy
   metadata:
     name: default-deny
   spec:
     order: 2000
     selector: "projectcalico.org/namespace in {'dev','default'}"
     types:
     - Ingress
     - Egress
   EOF
   ```

   You should be able to view the potential affect of the staged default-deny policy if you navigate to the Dashboard view in the Enterprise Manager UI and look at the Packets by Policy histogram.

   ```bash
   # make a request across namespaces and view Packets by Policy histogram, the expected result is "HTTP/1.1 200 OK"
   for i in {1..5}; do kubectl -n dev exec -t centos -- sh -c 'curl -m3 -sI http://frontend.default 2>/dev/null | grep -i http'; sleep 2; done
   ```

   The staged policy does not affect the traffic directly but allows you to view the policy impact if it were to be enforced. You can see the deny traffic in staged policy.


2. Create other network policies to individually allow the traffic shown as blocked in step 1, until no connections are denied.
  
   Apply network policies to your application with explicity allow and deny control.

   ```yaml
   kubectl apply -f - <<-EOF   
   apiVersion: projectcalico.org/v3
   kind: NetworkPolicy
   metadata:
     name: default.centos
     namespace: dev
   spec:
     tier: default
     order: 800
     selector: app == "centos"
     egress:
     - action: Allow
       protocol: TCP
       destination:
         selector: app == "nginx"
     types:
       - Egress
   EOF
   ```

3. Test connectivity with policies in place.

   a. The only connections between the components within namespaces dev are from centos to nginx, which should be allowed as configured by the policies.

   ```bash
   # test connectivity within dev namespace, the expected result is "HTTP/1.1 200 OK"
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -sI http://nginx-svc 2>/dev/null | grep -i http'
   ```
   
   The connections within namespace default should be allowed as usual.
   
   ```bash
   # test connectivity within default namespace in 8080 port
   kubectl exec -it $(kubectl get po -l app=frontend -ojsonpath='{.items[0].metadata.name}') \
   -c server -- sh -c 'nc -zv recommendationservice 8080'
   ``` 

   b. The connections across dev/centos pod and default/frontend pod should be blocked by the application policy.
   
   ```bash   
   # test connectivity from dev namespace to default namespace, the expected result is "command terminated with exit code 1"
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -sI http://frontend.default 2>/dev/null | grep -i http'
   ```

   c. Test connectivity from each namespace dev and default to the Internet.
   
   ```bash   
   # test connectivity from dev namespace to the Internet, the expected result is "command terminated with exit code 1"
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -sI http://www.google.com 2>/dev/null | grep -i http'
   ```
   
   ```bash
   # test connectivity from default namespace to the Internet, the expected result is "HTTP/1.1 200 OK"
   kubectl exec -it $(kubectl get po -l app=loadgenerator -ojsonpath='{.items[0].metadata.name}') \
   -c main -- sh -c 'curl -m3 -sI http://www.google.com 2>/dev/null | grep -i http'
   ```

4. Implement explicitic policy to allow egress access from a workload in one namespace/pod, e.g. dev/centos, to default/frontend.
   
   a. Deploy egress policy between two namespaces dev and default.

   ```yaml
   kubectl apply -f - <<-EOF
   apiVersion: projectcalico.org/v3
   kind: NetworkPolicy
   metadata:
     name: platform.centos-to-frontend
     namespace: dev
   spec:
     tier: platform
     order: 100
     selector: app == "centos"
     egress:
       - action: Allow
         protocol: TCP
         source: {}
         destination:
           selector: app == "frontend"
           namespaceSelector: projectcalico.org/name == "default"
       - action: Pass
     types:
       - Egress
   EOF
   ```

   b. Test connectivity between dev/centos pod and default/frontend service again, should be allowed now.

   ```bash   
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -sI http://frontend.default 2>/dev/null | grep -i http'
   #output is HTTP/1.1 200 OK
   ```

5. Apply the policies to allow the microservices to communicate with each other.

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/regismartins/cc-aks-security-compliance-workshop/main/manifests/east-west-traffic.yaml
   ```

6. Use the Calico Cloud GUI to enforce the default-deny staged policy. After enforcing a staged policy, it takes effect immediatelly. The default-deny policy will start to actually deny traffic.
   
---

## DNS Policies and NetworkSets

1. Implement DNS policy to allow the external endpoint access from a specific workload, e.g. `dev/centos`.

   a. Apply a policy to allow access to `api.twilio.com` endpoint using DNS rule.

   ```yaml
   kubectl apply -f - <<-EOF
   apiVersion: projectcalico.org/v3
   kind: GlobalNetworkPolicy
   metadata:
     name: security.external-domain-access
   spec:
     tier: security
     selector: (app == "centos" && projectcalico.org/namespace == "dev")
     order: 100
     types:
       - Egress
     egress:
     - action: Allow
       source:
         selector: app == 'centos'
       destination:
         domains:
         - '*.twilio.com'
   EOF
   ```
   
   Test the access to the endpoints:

   ```bash
   # test egress access to api.twilio.com
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -skI https://api.twilio.com 2>/dev/null | grep -i http'
   ```

   ```bash
   # test egress access to www.google.com
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -skI https://www.google.com 2>/dev/null | grep -i http'
   ```

   Access to the `api.twilio.com` endpoint should be allowed by the DNS policy and any other external endpoints like `www.google.com` should be denied.

   b. Modify the policy to include `*.google.com` in dns policy and test egress access to www.google.com again.

   ```bash
   # test egress access to www.google.com again and it should be allowed.
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -skI https://www.google.com 2>/dev/null | grep -i http'
   ```

2. Edit the policy to use a `NetworkSet` with DNS domain instead of inline DNS rule.

   a. Apply a policy to allow access to `api.twilio.com` endpoint using DNS policy.

   Deploy the Network Set

   ```yaml
   kubectl apply -f - <<-EOF
   kind: GlobalNetworkSet
   apiVersion: projectcalico.org/v3
   metadata:
     name: allowed-dns
     labels: 
       type: allowed-dns
   spec:
     allowedEgressDomains:
     - '*.twilio.com'
   EOF
   ```

   b. Deploy the DNS policy using the network set

   ```yaml
   kubectl apply -f - <<-EOF
   apiVersion: projectcalico.org/v3
   kind: GlobalNetworkPolicy
   metadata:
     name: security.external-domain-access
   spec:
     tier: security
     selector: (app == "centos" && projectcalico.org/namespace == "dev")
     order: 100
     types:
       - Egress
     egress:
     - action: Allow
       destination:
         selector: type == "allowed-dns"
   EOF
   ```

   c. Test the access to the endpoints.

   ```bash
   # test egress access to api.twilio.com
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -skI https://api.twilio.com 2>/dev/null | grep -i http'
   ```

   ```bash
   # test egress access to www.google.com
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -skI https://www.google.com 2>/dev/null | grep -i http'
   ```

   d. Modify the `NetworkSet` to include `*.google.com` in dns domain and test egress access to www.google.com again.

   ```bash
   # test egress access to www.google.com again and it should be allowed.
   kubectl -n dev exec -t centos -- sh -c 'curl -m3 -skI https://www.google.com 2>/dev/null | grep -i http'
   ```

## Ingress Policies using NetworkSets

The NetworkSet can also be used to block access from a specific ip address or cidr to an endpoint in your cluster. To demonstrate it, we are going to block the access from your workstation to the Online Boutique frontend-external service.

   a. Test the access to the frontend-external service

   ```bash
   curl -sI -m3 $(kubectl get svc frontend-external -ojsonpath='{.status.loadBalancer.ingress[0].ip}') | grep -i http
   ```
   
   b. Identify your workstation ip address and store it in a environment variable

   ```bash
   export MY_IP=$(curl ifconfig.me)
   ```

   c. Create a NetworkSet with your ip address on it.

   ```yaml
   kubectl apply -f - <<-EOF
   kind: GlobalNetworkSet
   apiVersion: projectcalico.org/v3
   metadata:
     name: ip-address-list
     labels: 
       type: blocked-ips
   spec:
     nets:
     - $MY_IP/32
   EOF
   ```
   
   d. Create the policy to deny access to the frontend service.

   ```yaml
   kubectl apply -f - <<-EOF
   apiVersion: projectcalico.org/v3
   kind: GlobalNetworkPolicy
   metadata:
     name: security.blockep-ips
   spec:
     tier: security
     selector: app == "frontend"
     order: 300
     types:
       - Ingress
     ingress:
     - action: Deny
       source:
         selector: type == "blocked-ips"
       destination: {}
     - action: Pass
       source: {}
       destination: {}
   EOF
   ```

   e. Create a global alert for the blocked attempt from the ip-address-list to the frontend.

   ```yaml
   kubectl apply -f - <<-EOF   
   apiVersion: projectcalico.org/v3
   kind: GlobalAlert
   metadata:
     name: blocked-ips
   spec:
     description: "A connection attempt from a blocked ip address just happened."
     summary: "[blocked-ip] ${source_ip} from ${source_name_aggr} networkset attempted to access ${dest_namespace}/${dest_name_aggr}"
     severity: 100
     dataSet: flows
     period: 1m
     lookback: 1m
     query: '(source_name = "ip-address-list")'
     aggregateBy: [dest_namespace, dest_name_aggr, source_name_aggr, source_ip]
     field: num_flows
     metric: sum
     condition: gt
     threshold: 0
   EOF
   ```

   a. Test the access to the frontend-external service. It is blocked now. Wait a few minutes and check the `Activity > Alerts`.

   ```bash
   curl -sI -m3 $(kubectl get svc frontend-external -ojsonpath='{.status.loadBalancer.ingress[0].ip}') | grep -i http
   ```

## Microsegmentation

Calico eliminates the risks associated with lateral movement in the cluster to prevent access to sensitive data and other assets. Calico provides a unified, cloud-native segmentation model and single policy framework that works seamlessly across multiple application and workload environments. It enables faster response to security threats
with a cloud-native architecture that can dynamically enforce security policy changes across cloud environments in milliseconds in response to an attack.

 
## Microsegmentation using label PCI = true on a namespace

1. For the microsegmentation deploy a new example application

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/regismartins/cc-aks-security-compliance-workshop/main/manifests/storefront-pci.yaml
   ```

2. Verify that all the workloads has the label `PCI=true`.

   ```bash
   kubectl get pods -n storefront --show-labels
   ```

3. Create a policy that only allows endpoints with label PCI=true to communicate.

   ```yaml
   kubectl apply -f - <<-EOF
   apiVersion: projectcalico.org/v3
   kind: GlobalNetworkPolicy
   metadata:
     name: security.pci-whitelist
   spec:
     tier: security
     order: 100
     selector: projectcalico.org/namespace == "storefront"
     ingress:
     - action: Deny
       source:
         selector: PCI != "true"
       destination:
         selector: PCI == "true"
     - action: Pass
       source:
       destination:
     egress:
     - action: Allow
       protocol: UDP
       source: {}
       destination:
         selector: k8s-app == "kube-dns"
         ports:
         - '53'
     - action: Deny
       source:
         selector: PCI == "true"
       destination:
         selector: PCI != "true"
     - action: Pass
       source:
       destination:
     types:
     - Ingress
     - Egress
   EOF
   ```

Now only the pods labeled with PCI=true will be able to exchange information. Note that you can use different labels to create any sort of restrictions for the workloads communications.

---

## Policy lifecycle management


With Calico, teams can create, preview, and deploy security policies based on the characteristics and metadata
of a workload. These policies can provide an automated and scalable way to manage and isolate workloads for
security and compliance. You can automate a validation step that ensures your security policy works properly before being committed. Calico can deploy your policies in a “staged” mode that will display which traffic is being allowed or denied before the policy rule is enforced. The policy can then be committed if it is operating properly. This step avoids any potential problems caused by incorrect, incomplete, or
conflicting security policy definitions.

1. Open a policy and check the change log

![change-log](https://user-images.githubusercontent.com/104035488/192361358-33ad8ab4-0c86-4892-a775-4d3bfc72ba38.gif)

# Thank you!

--- 

**Useful links**

- [Project Calico](https://www.tigera.io/project-calico/)
- [Calico Academy - Get Calico Certified!](https://academy.tigera.io/)
- [O’REILLY EBOOK: Kubernetes security and observability](https://www.tigera.io/lp/kubernetes-security-and-observability-ebook)
- [Calico Users - Slack](https://slack.projectcalico.org/)

**Follow us on social media**

- [LinkedIn](https://www.linkedin.com/company/tigera/)
- [Twitter](https://twitter.com/tigeraio)
- [YouTube](https://www.youtube.com/channel/UC8uN3yhpeBeerGNwDiQbcgw/)
- [Slack](https://calicousers.slack.com/)
- [Github](https://github.com/tigera-solutions/)
- [Discuss](https://discuss.projectcalico.tigera.io/)

---

[:arrow_up: Back to the top](/README.md#calico-cloud-demo-on-an-eks-cluster)
