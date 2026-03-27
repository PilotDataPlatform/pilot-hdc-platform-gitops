#!/usr/bin/env bash
# Creates the XWiki Vault secret (secret/xwiki) from scratch.
# Generates: PG password, cookie validation/encryption keys.
# Requires: OIDC_SECRET env var (from terraform output -raw xwiki_client_secret)
#
# Usage:
#   kubectl port-forward -n vault vault-0 8200:8200 &
#   OIDC_SECRET=<value> bash scripts/vault-xwiki.sh
#
# Env-specific values to change for prod:
#   - xwiki.home          → https://xwiki.hdc.ebrains.eu
#   - oidc.xwikiprovider  → https://xwiki.hdc.ebrains.eu/oidc
#   - oidc.endpoint.*     → iam.hdc.ebrains.eu (drop .dev)
#   - oidc.groups.claim   → must match KC group mapper claim_name (currently "group")
set -euo pipefail

export VAULT_ADDR=http://127.0.0.1:8200

PG_PASS=$(openssl rand -hex 16)
VALIDATION_KEY=$(openssl rand -hex 16)
ENCRYPTION_KEY=$(openssl rand -hex 16)

if [[ -z "${OIDC_SECRET:-}" ]]; then
  echo "ERROR: Set OIDC_SECRET first (from terraform output -raw xwiki_client_secret)" >&2
  exit 1
fi

vault kv put secret/xwiki \
  postgresql-password="$PG_PASS" \
  xwiki-cfg="xwiki.encoding=UTF-8
xwiki.store.migration=1

xwiki.home=https://xwiki.dev.hdc.ebrains.eu
xwiki.url.protocol=https
xwiki.webapppath=
xwiki.inactiveuser.allowedpages=

xwiki.authentication.authclass=org.xwiki.contrib.oidc.auth.OIDCAuthServiceImpl
xwiki.authentication.validationKey=$VALIDATION_KEY
xwiki.authentication.encryptionKey=$ENCRYPTION_KEY
xwiki.authentication.cookiedomains=
xwiki.authentication.logoutpage=(/|/[^/]+/|/wiki/[^/]+/)logout/*

xwiki.defaultskin=flamingo
xwiki.defaultbaseskin=flamingo
xwiki.section.edit=1
xwiki.section.depth=2
xwiki.backlinks=1
xwiki.tags=1
xwiki.stats.default=0
xwiki.editcomment=1
xwiki.editcomment.mandatory=0
xwiki.plugin.image.cache.capacity=30

xwiki.plugins=\\
  com.xpn.xwiki.monitor.api.MonitorPlugin,\\
  com.xpn.xwiki.plugin.skinx.JsSkinExtensionPlugin,\\
  com.xpn.xwiki.plugin.skinx.JsSkinFileExtensionPlugin,\\
  com.xpn.xwiki.plugin.skinx.JsResourceSkinExtensionPlugin,\\
  com.xpn.xwiki.plugin.skinx.CssSkinExtensionPlugin,\\
  com.xpn.xwiki.plugin.skinx.CssSkinFileExtensionPlugin,\\
  com.xpn.xwiki.plugin.skinx.CssResourceSkinExtensionPlugin,\\
  com.xpn.xwiki.plugin.skinx.LinkExtensionPlugin,\\
  com.xpn.xwiki.plugin.feed.FeedPlugin,\\
  com.xpn.xwiki.plugin.mail.MailPlugin,\\
  com.xpn.xwiki.plugin.packaging.PackagePlugin,\\
  com.xpn.xwiki.plugin.svg.SVGPlugin,\\
  com.xpn.xwiki.plugin.fileupload.FileUploadPlugin,\\
  com.xpn.xwiki.plugin.image.ImagePlugin,\\
  com.xpn.xwiki.plugin.diff.DiffPlugin,\\
  com.xpn.xwiki.plugin.rightsmanager.RightsManagerPlugin,\\
  com.xpn.xwiki.plugin.jodatime.JodaTimePlugin,\\
  com.xpn.xwiki.plugin.scheduler.SchedulerPlugin,\\
  com.xpn.xwiki.plugin.mailsender.MailSenderPlugin,\\
  com.xpn.xwiki.plugin.tag.TagPlugin,\\
  com.xpn.xwiki.plugin.zipexplorer.ZipExplorerPlugin" \
  xwiki-properties="environment.permanentDirectory=/usr/local/xwiki/data

oidc.xwikiprovider=https://xwiki.dev.hdc.ebrains.eu/oidc
oidc.endpoint.authorization=https://iam.dev.hdc.ebrains.eu/realms/hdc/protocol/openid-connect/auth
oidc.endpoint.token=https://iam.dev.hdc.ebrains.eu/realms/hdc/protocol/openid-connect/token
oidc.endpoint.userinfo=https://iam.dev.hdc.ebrains.eu/realms/hdc/protocol/openid-connect/userinfo
oidc.scope=openid,profile,email,groups
oidc.endpoint.userinfo.method=GET
oidc.user.nameFormater=\${oidc.user.preferredUsername._clean._lowerCase}
oidc.user.subjectFormater=\${oidc.user.subject}
oidc.userinfoclaims=group
oidc.clientid=xwiki
oidc.secret=$OIDC_SECRET
oidc.endpoint.token.auth_method=client_secret_basic
oidc.skipped=false
oidc.groups.claim=group"

echo "Done."
echo "  PG password: $PG_PASS"
echo "  Validation key: $VALIDATION_KEY"
echo "  Encryption key: $ENCRYPTION_KEY"
