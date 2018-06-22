#!/bin/bash

utils_setup() {
    sudo apt-get install -y apache2-utils
}

docker_setup() {
    sudo apt-get remove docker docker-engine docker.io docker-ce
    sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common jq
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    sudo apt-get install -y docker-ce
}

gce_setup() {
    export CLOUD_SDK_REPO="cloud-sdk-$(lsb_release -c -s)"
    echo "deb http://packages.cloud.google.com/apt $CLOUD_SDK_REPO main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    sudo apt-get update && sudo apt-get install google-cloud-sdk
    sudo apt-get install kubectl
    echo -n "$GCE_SERVICE_ACCOUNT" | base64 -d > "$HOME/.gcloud_credentials.json"
    gcloud auth activate-service-account --key-file="$HOME/.gcloud_credentials.json"
    gcloud config set disable_prompts true
    gcloud config set compute/zone $GCE_ZONE
    gcloud config set compute/region $GCE_REGION
    gcloud config set project $GCE_PROJECT
}

wait_for_pod() {
    sleep 30

    POD=$1
    WAIT=${2:-100}
    for i in {0..$WAIT}; do
        KUBECTL=$(kubectl get pod $POD -o=jsonpath='{.status.containerStatuses[0].ready}' || echo false)
        if [ "$KUBECTL" == "true" ]; then
            break;
        fi;
        sleep 1;
    done
}

retag_payloads() {
    for payload in kubernetes/pxc-statefulset.yml kubernetes/proxysql-statefulset.yml php-test-artifact/artifact-statefulset.yml; do
        sed -i'' -e 's#(image: nlpsecure/.+:).*#\1$TAG\"#g' $payload
    done
}

generate_safe_tag() {
    export TAG=$(echo "$TRAVIS_BRANCH" | sed -e 's/\W/_/g')
}

generate_cluster_name() {
    export CLUSTER_NAME="travis-$( echo $TAG | sed -e 's/[\W_]/-/g' | head -c 39 )"
}

boot_gke_cluster() {
    gcloud container clusters delete $CLUSTER_NAME || true
    gcloud container clusters create $CLUSTER_NAME --machine-type=n1-standard-1 --node-locations=$GCE_ZONES --num-nodes=1 --enable-autorepair --enable-autoupgrade 
    gcloud container clusters get-credentials $CLUSTER_NAME
    export ACCOUNT=$(gcloud info --format='value(config.account)')
    kubectl delete limitrange limits
    kubectl create clusterrolebinding owner-cluster-admin-binding --clusterrole cluster-admin --user $ACCOUNT
    echo "Cluster name is $CLUSTER_NAME"
}

docker_login() {
    echo $DOCKER_PASSWORD | docker login -u $DOCKER_USER --password-stdin
}

docker_get_jwt() {
    echo -n "Authorization: JWT " > .jwt
    curl -X POST \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d '{"username":"$DOCKER_USER","password":"$DOCKER_USER"}' \
            https://hub.docker.com/v2/users/login/ | jq -r ".token" >> .jwt
}

docker_pull_build_push() {
    for repo_and_path in \
        $PXC_REPO:percona-xtradb-57 \
        $PROXYSQL_REPO:proxysql \
        $PHP_TEST_ARTIFACT_REPO:php-test-artifact
    do
        repo=$(echo $repo_and_path | awk '{ split($0, a, ":"); print a[1]; }')
        path=$(echo $repo_and_path | awk '{ split($0, a, ":"); print a[2]; }')
        docker pull $repo || true
        docker build -t $repo:latest $path
        docker tag $repo:latest $repo:$TAG
        docker push $repo:$TAG
    done
}

untag_images() {
    if [ "$TAG" != "latest" ]; then
        for user_and_repo in $PXC_REPO $PROXYSQL_REPO $PHP_TEST_ARTIFACT_REPO; do
            set +x
            curl -X DELETE \
                -H "Accept: application/json" \
                -H "@.jwt" \
                "https://hub.docker.com/v2/repositories/$user_and_repo/tags/$TAG/"
        done
    fi
}

docker_expire_jwt() {
    curl -i -X POST \
        -H "Accept: application/json" \
        -H "@.jwt" \
        "https://hub.docker.com/v2/logout/"
}

prep_pxc_cluster() {
    kubectl create -f kubernetes/pxc-serviceaccount.yml
    kubectl create -f kubernetes/pxc-pv-host.yml
    kubectl create -f kubernetes/pxc-secrets.yml
    kubectl create -f kubernetes/pxc-services.yml

    retag_payloads $TAG
}

boot_pxc_cluster() {
    kubectl create -f kubernetes/pxc-statefulset.yml
    wait_for_pod mysql-0
}

boot_proxysql() {
    kubectl create -f kubernetes/proxysql-service.yml
    kubectl create -f kubernetes/proxysql-statefulset.yml
    wait_for_pod proxysql-0
}

boot_test_artifact() {
    kubectl create -f php-test-artifact/artifact-service.yml
    kubectl create -f php-test-artifact/artifact-statefulset.yml
}

whack_test_artifact() {
    export AB_RESULTS=$(
        kubectl proxy --port=80 php-test-artifact-0:80 &
        ab -n 50 -c 2 http://localhost/
        kill %1
    )
}

check_logs() {
    POD=$1
    LOGS=$(kubectl logs $POD)
    case $POD in
        mysql-0)
            export LOGS_0="$LOGS"
            ;;
        mysql-1)
            export LOGS_1="$LOGS"
            echo -n "$LOGS_1" | grep 'WSREP: 0.0 (mysql-0): State transfer to 1.0 (mysql-1) complete'
            echo -n "$LOGS_1" | grep 'WSREP: Synchronized with group, ready for connections'
            ;;
        mysql-2)
            export LOGS_2="$LOGS"
            echo -n "$LOGS_2" | grep 'WSREP: 0.0 (mysql-0): State transfer to 2.0 (mysql-2) complete'
            echo -n "$LOGS_2" | grep 'WSREP: Synchronized with group, ready for connections'
            ;;
        proxysql-0)
            export PROXYSQL_LOGS="$LOGS"
            ;;
        php-test-artifact-0)
            export PHP_TEST_ARTIFACT_LOGS="$LOGS"
            ;;
    esac
}

deploy() {
    docker push $PXC_REPO:latest
    docker push $PROXYSQL_REPO:latest

    if [ -n "$TRAVIS_TAG" ]; then
        docker tag $PXC_REPO:latest $PXC_REPO:$TRAVIS_TAG
        docker push $PXC_REPO:$TRAVIS_TAG
        docker tag $PROXYSQL_REPO:latest $PROXYSQL_REPO:$TRAVIS_TAG
        docker push $PROXYSQL_REPO:$TRAVIS_TAG
    fi
}