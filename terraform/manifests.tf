data "kubectl_path_documents" "yamls" {
    pattern = "../manifests-tf/*.yaml"
}

resource "kubectl_manifest" "test" {
    for_each  = toset(data.kubectl_path_documents.yamls.documents)
    yaml_body = each.value
}