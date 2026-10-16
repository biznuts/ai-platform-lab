# Secrets (local only)

Terraform reads one value per file from this folder. Everything here except this README and the
`*.example` files is gitignored. Create the real files on your workstation:

```bash
cd terraform/secrets
for f in litellm_master_key postgres_password mcp_token_finance mcp_token_hr; do
  python -c "import secrets; print(secrets.token_urlsafe(32))" > "$f"
done
# LiteLLM requires the master key to start with "sk-":
python -c "import secrets; print('sk-' + secrets.token_urlsafe(32))" > litellm_master_key
# Your Cohere trial key (personal account), one line:
cp cohere_api_key.example cohere_api_key && "${EDITOR:-nano}" cohere_api_key
chmod 600 *
```

The values also land in `terraform.tfstate` (gitignored). Keep the state on your workstation and
delete it when the lab is torn down. Rotate any key you have pasted anywhere else.
