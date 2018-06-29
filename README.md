Percona XtraDB Cluster docker image
===================================

The goal of this image and the surrounding ecosystem (at https://github.com/nlp-secure/percona-docker/) is to provide an off-the-shelf enterprise HA cloud-oriented Kubernetes turn-key solution that requires a minimum of setup and provides best practices by default: reliable bootup, monitoring (via PMM), online scheduled backups 24/7, monitoring, SSL, failover, proxying, zonal separation, and built-in restoration processes.  All of these guarantees are to be gated pre-release by modern CI/CD processes.

Right now, we're at: reliable bootup and bootstrapping, online scheduled backups, failover handling, and zonal separation.

The docker image is available right now at `nlpsecure/percona-xtradb-57:latest`.

All releases are gated by Travis-CI building a cluster from scratch, placing ProxySQL (below) in front of the cluster, and exercising various functions of the cluster - more to come as time allows and contributors join.

Basic usage
-----------

Create a Kubernetes cluster using Google's Kubernetes Engine at cloud.kubernetes.com with 1 node and availability in 3 zones in the same region.  Set up your command line tools according to [Google's](https://cloud.google.com/kubernetes-engine/docs/quickstart) docs and then after inspecting/editing to your preferences, run the following commands from the path of this README:

```bash
# Set your desired namespace here; I'm using pxc-test.  I do this just so that
# I can muck around and not accidentally break anything important without *really* trying.
kubectl config set-context $(kubectl config current-context) --namespace=pxc-test

# Note: the values in this file should be base64-encoded for k8s' consumption :)
kubectl create -f kubernetes/pxc-secrets.yml

kubectl create -f kubernetes/pxc-services.yml
kubectl create -f kubernetes/pxc-pv-host.yml
kubectl create -f kubernetes/pxc-statefulset.yml

# Watch your cluster come online with:
kubectl get pod

# As each member comes online, you can view its status with:
kubectl logs -f mysql-#
# Obviously, subsitute the node number up there.

# To rip the whole thing down for starting over is simple enough:
kubectl delete -f kubernetes/pxc-statefulset.yml; kubectl delete -f kubernetes/pxc-pv-host.yml; kubectl delete pvc --all

# Then you can boot a next iteration with:
kubectl create -f kubernetes/pxc-pv-host.yml; kubectl create -f kubernetes/pxc-statefulset.yml

# You can periodically delete nodes just to watch them come back online if you like;
# just don't delete all three at once - if you do this, you'll have to bootstrap,
# which is less than a fun day at the park.

# Once you're done, switch back to your default namespace with:
kubectl config set-context $(kubectl config current-context) --namespace=default

# If you were just testing, you can delete *everything* in one pass just by deleting the namespace:
kubectl delete ns pxc-test
```

Within the next day or two I should drive classes set up for running multi-zonal Google drives, EBS drives, etc.

Running with ProxySQL
---------------------

ProxySQL is now being added into the mix under the nlpsecure/proxysql container; however 

Monitoring with Prometheus
---------------------------

This section is to be added in the near future


Maintaining and Restoring Backups
---------------------------------

This has been added but not yet documented.  Encrypted backups to AWS S3 using cron in each container is the current strategy - which is less optimal than having a Kubernetes CronJob trigger them on a consistent basis; however it's a decent starting point.