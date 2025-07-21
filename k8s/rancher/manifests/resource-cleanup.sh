function job_control() {
  joblist=($(jobs -p))
  while (( ${#joblist[*]} >= 15 ))
  do
    sleep 1
    joblist=($(jobs -p))
  done
}

function extract_finalizer() {
  jq -Mcr '.metadata.finalizers // [] | {metadata:{finalizers:map(select(. | (contains("controller.cattle.io/") or contains("wrangler.cattle.io/")) | not ))}}'
}

function patch_finalizer() {
  echo patching $1/$2
  job_control
#  kubectl patch --dry-run=client $1 $2 --type=merge -p $(kubectl get $1 $2 -o json | extract_finalizer) &
  kubectl patch $1 $2 --type=merge -p '{"metadata":{"finalizers":[]}}' &
  kubectl delete $1 $2 &
}

kubectl delete validatingwebhookconfigurations rancher.cattle.io
kubectl delete MutatingWebhookConfiguration rancher.cattle.io

NS_TYPES=$(kubectl api-resources --verbs=list -o name --namespaced=true | grep "cattle.io")
for type in $NS_TYPES; do
    echo "Removing finalizers for $type"
    kubectl get $type --all-namespaces -o custom-columns='NAMESPACE:.metadata.namespace','NAME:.metadata.name' --no-headers | while read line; do set $line; patch_finalizer "-n $1" $type/$2; done
done

CLUSTER_TYPES=$(kubectl api-resources --verbs=list -o name --namespaced=false | grep "cattle.io")
for type in $CLUSTER_TYPES; do
    echo "Removing finalizers for $type"
    kubectl get $type -o name --show-kind --no-headers | while read line; do patch_finalizer "" $line; done
done

kubectl get crds -o name | grep cattle | while read line; do patch_finalizer "" $line; done
kubectl get ns |grep Terminating | while read line; do patch_finalizer "" namespace/$line; done
