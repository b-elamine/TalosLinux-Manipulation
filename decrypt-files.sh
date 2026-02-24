export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

for CLUSTER in dev staging prod; do
  for FILE in controlplane.yaml worker.yaml talosconfig; do
    if [ -f "clusters/${CLUSTER}/${FILE}" ]; then
      sops --decrypt --in-place clusters/${CLUSTER}/${FILE}
      echo "Decrypted clusters/${CLUSTER}/${FILE}"
    fi
  done
done
