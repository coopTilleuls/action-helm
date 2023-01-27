#!/bin/bash

set -ex
export PREFIX_NAME=$PREFIX_NAME

# set helm values file
if [ -f ../helm/chart/values.yaml ]; then
    HELM_ARG="$HELM_ARG -f ../helm/chart/values.yaml"
fi
if [ -f ../helm/chart/values-$PREFIX_NAME.yaml ]; then
    HELM_ARG="$HELM_ARG -f ../helm/chart/values-$PREFIX_NAME.yaml"
else
    if [ -f ../helm/chart/values-pullrequest.yaml ]; then
    HELM_ARG="$HELM_ARG -f ../helm/chart/values-pullrequest.yaml"
    fi
fi

# Helm chart information
if [ ! -f ../helm/chart/HELM_ENV ]; then
    echo "helm/chart/HELM_ENV is missing, using local chart instead" 1>&2
    HELM_CHART_NAME=helm/chart/
else
    source ../helm/chart/HELM_ENV
    if [ -z "$HELM_CHART_REPO" ]; then
    echo "Missing HELM_CHART_REPO in helm/chart/HELM_ENV file" 1>&2
    exit 1
    fi
    if [ -z "$HELM_CHART_NAME" ]; then
    echo "Missing HELM_CHART_NAME in helm/chart/HELM_ENV file" 1>&2
    exit 1
    fi
    if [ -z "$HELM_CHART_VERSION" ]; then
    echo "Missing HELM_CHART_VERSION in helm/chart/HELM_ENV file" 1>&2
    exit 1
    fi
fi

if [ -n "$HELM_CHART_REPO" ] ; then
    helm repo add repo $HELM_CHART_REPO
    HELM_CHART_OPTIONS="repo/$HELM_CHART_NAME --version $HELM_CHART_VERSION"
else
    HELM_CHART_OPTIONS="$HELM_CHART_NAME"
    helm dependency build $HELM_CHART_NAME
fi

if [ "$ACTION" == "install" ]; then
    # test access
    kubectl get pods
    echo "Current installed releases in namespace:"
    helm list

    echo "Installing/Updating release:"
    # sed is used to rm USER-SUPPLIED VALUES from helm debug
    if ! helm upgrade --install $PREFIX_NAME $HELM_CHART_OPTIONS --atomic --debug --wait --timeout $TIMEOUT \
        $HELM_VALUES_ARG \
        $HELM_ARG \
        | sed --unbuffered '/USER-SUPPLIED VALUES/,$d' ; then
    echo "Deployment has failed!"
    echo "Here are the last events to help diagnose the problem:"
    kubectl get events --sort-by .metadata.creationTimestamp
    exit 1
    fi
    echo "Deployment successful"
    # getting Ingress hosts :
    echo INGRESS_HOSTS_JSON=$(helm get manifest $PREFIX_NAME | yq ea '[. | select(.kind=="Ingress") | .spec.rules[].host ]' --output-format=json -I 0) >> $GITHUB_OUTPUT
fi

if [ "$ACTION" == "uninstall" ]; then
    # test access
    kubectl get pods
    echo "Current installed releases in namespace:"
    helm list
    echo "Uninstalling release $PREFIX_NAME"
    if ! helm uninstall $PREFIX_NAME --wait ; then
    echo "Helm uninstall has failed!"
    echo "Please ask the SRE team to manually clean remaining objects"
    exit 1
    fi
    echo "Helm uninstall successful"
fi

if [ "$ACTION" == "check" ]; then
    helm template $HELM_CHART_OPTIONS \
    $HELM_VALUES_ARG \
    $HELM_ARG | yq e -s '"yq_tmp_" + $index' -
    for file in yq_tmp_*.yml; do
    echo "Checking if metadata.name is prefixed by release name on $(yq e '.kind + "/" + .metadata.name' $file)"
    yq -C --exit-status e '.metadata.name | test("release-name-")' $file
    # TODO: add more checks
    # TODO: liveness/readiness on all apps
    done
    rm yq_tmp_*.yml
fi