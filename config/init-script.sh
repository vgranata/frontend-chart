#!/bin/bash

set -x

# Abort the whole init instead of silently continuing on a failed download --
# a network hiccup here (e.g. right after a minikube restart, before the
# node's networking is fully up) must not be allowed to fall through into
# drush writing corrupt/empty data into the database.
require_pipe_ok() {
    local status=("${PIPESTATUS[@]}")
    for s in "${status[@]}"; do
        if [ "$s" -ne 0 ]; then
            echo "FATAL: $1 failed (pipe exit codes: ${status[*]}) -- aborting init-script.sh rather than continuing with a possibly incomplete/corrupt result." >&2
            exit 1
        fi
    done
}

# Install jq if not available
JQ_URL=https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
JQ_BIN=/usr/local/bin/jq
which jq 2>&1 > /dev/null || { curl -sfL $JQ_URL -o $JQ_BIN && chmod +x $JQ_BIN ; }
if ! jq --version > /dev/null 2>&1; then
    echo "FATAL: jq is not installed and could not be downloaded from $JQ_URL -- aborting init-script.sh rather than running drush commands we can't correctly script without it." >&2
    exit 1
fi

# Generate settings.php from template
cd /patched-files
cp /frontend-config/settings.php settings.php
sed -i "s/%%MYSQL_PASSWORD%%/${MYSQL_PASSWORD}/" settings.php

# avoid db deadlocks, see https://groups.drupal.org/node/415883
cat <<- 'EOF' >> settings.php
$databases['default']['default']['init_commands'] = array(
    'isolation' => "SET SESSION transaction_isolation='READ-COMMITTED'"
);
EOF

echo '#####'
cat settings.php
echo '#####'

cp settings.php /var/www/mmoda/sites/default/settings.php

# sites/all/modules/mmoda is a broken self-referential symlink in some
# published image tags (-> ../../../../mmoda, resolving back to the Drupal
# root itself /var/www/mmoda). /mmoda-module-src is a shared emptyDir volume
# mounted at a *separate*, non-symlinked path in both this init container and
# the main container (see deployment.yaml) -- mounting a volume directly at
# the symlinked path itself was tried and is unsafe: the mount follows the
# symlink to its resolved target and ends up shadowing the whole
# /var/www/mmoda tree instead of just the module directory. Populate the
# clean path instead, patch the resolver URL there once so both containers
# see the patched version, then point each container's own
# sites/all/modules/mmoda at it via a fresh symlink (done separately for the
# main container in deployment.yaml, since it doesn't run this script).
echo "Populating /mmoda-module-src from oda-hub/mmoda-frontend-module"
curl -sfL https://github.com/oda-hub/mmoda-frontend-module/archive/refs/heads/master.tar.gz \
    | tar xz --strip-components=1 -C /mmoda-module-src
require_pipe_ok "fetching/extracting oda-hub/mmoda-frontend-module"

sed -i 's@$local_name_resolver_url = "https://resolver-prod.obsuks1.unige.ch/api/v1.1/byname/";@$local_name_resolver_url = "{{ .Values.resolver_endpoint }}";@' /mmoda-module-src/mmoda.nameresolver.inc

# jquery.serializeJSON is a Libraries API dependency mmoda.module expects at
# sites/all/libraries/jquery.serializeJSON/jquery.serializejson.min.js, but
# it's missing from this image's baked-in sites/all/libraries (unlike
# colorbox, datatables, ckeditor, etc., which are present) -- not shared with
# any other container path, so no symlink concerns here, just populate it.
echo "Populating sites/all/libraries/jquery.serializeJSON from marioizquierdo/jquery.serializeJSON"
curl -sfL https://github.com/marioizquierdo/jquery.serializeJSON/archive/refs/heads/master.tar.gz \
    | tar xz --strip-components=1 -C /var/www/mmoda/sites/all/libraries/jquery.serializeJSON
require_pipe_ok "fetching/extracting marioizquierdo/jquery.serializeJSON"

MMODA_MODULE_DIR=/var/www/mmoda/sites/all/modules/mmoda
rm -rf "$MMODA_MODULE_DIR"
ln -s /mmoda-module-src "$MMODA_MODULE_DIR"

# sites/all/themes/bootstrap_mmoda is a broken symlink in some published image
# tags too (-> ../../../../bootstrap_mmoda/, which doesn't exist at all) --
# same defect class as the mmoda module symlink above, same fix: populate a
# separate, non-symlinked shared path and re-point the symlink at it (done
# separately for the main container in deployment.yaml).
echo "Populating /bootstrap-mmoda-theme-src from oda-hub/mmoda-frontend-theme"
curl -sfL https://github.com/oda-hub/mmoda-frontend-theme/archive/refs/heads/master.tar.gz \
    | tar xz --strip-components=1 -C /bootstrap-mmoda-theme-src
require_pipe_ok "fetching/extracting oda-hub/mmoda-frontend-theme"

BOOTSTRAP_MMODA_THEME_DIR=/var/www/mmoda/sites/all/themes/bootstrap_mmoda
rm -rf "$BOOTSTRAP_MMODA_THEME_DIR"
ln -s /bootstrap-mmoda-theme-src "$BOOTSTRAP_MMODA_THEME_DIR"

cp -rfv /frontend-default-files/* /var/www/mmoda/sites/default/files

[ -d /instruments-dir ] && cp -rfv /var/www/mmoda/sites/all/modules/mmoda/instruments/* /instruments-dir
# other way around. If there were instruments initialised, they need to be in the fs 
[ -d /instruments-dir ] && cp -rfv /instruments-dir/* /var/www/mmoda/sites/all/modules/mmoda/instruments/

# wait db
function run-sql() {
    mysql -h mysql -u astrooda -p$MYSQL_PASSWORD astrooda < ${1:?}
}
while ! run-sql <(echo ";") ; do 
    sleep 10
done

cd /var/www/mmoda
PATH=~/.composer/vendor/bin:$PATH

#drush -y updb
if drush sql-query "SELECT 1 FROM variable LIMIT 1;" > /dev/null 2>&1; then
    echo "Existing Drupal database detected, running database updates"
    drush -y updb
else
    echo "No existing Drupal database detected, performing fresh site-install"
    drush -y site-install minimal --account-name=admin --account-pass="$DRUPAL_PW" --site-name="MMODA local dev"
fi

# jquery_update isn't mmoda_*-prefixed so the enable logic below never
# touches it, but the theme/JS (BootstrapValidator, DataTables, etc.) require
# it: Drupal core's own bundled jQuery (1.4.4) predates .on() (added 1.7) and
# fails their version checks. Production/staging never hit this because their
# DB already has it enabled from history; a fresh site-install doesn't.
# Its default version (1.12, see JQUERY_UPDATE_DEFAULT_JQUERY_VERSION) is
# already sufficient once enabled, no variable configuration needed.
drush en -y jquery_update

# Drush reinstall all mmoda modules (in case new variables defined)
ALL_MMODA_MODULES=`drush pm-list --type=module --format=json | jq -r '[ keys[] | select(startswith("mmoda_")) ] | join(",")'`
ENABLED_MMODA_MODULES=`drush pm-list --type=module --status=enabled --format=json | jq -r '[ keys[] | select(startswith("mmoda_")) ] | join(",")'`
drush dis -y mmoda
drush pm-uninstall -y $ALL_MMODA_MODULES
drush pm-uninstall -y mmoda
drush en -y mmoda
drush en -y $MMODA_MODULES_FORCE_ENABLE
drush en -y $ENABLED_MMODA_MODULES


chmod -R 777 /var/www/mmoda/sites/default/files

#reset drupal admin
drush user-create admin --password=$DRUPAL_PW
# user-create will fail with default dump as it already exists, that's ok
drush sql-query "UPDATE users SET mail='$SITE_EMAIL_FROM' WHERE name='admin';"
drush user-unblock admin # in case it was blocked in the dump
drush user-add-role "administrator" admin
drush upwd --password=$DRUPAL_PW admin

drush vset -y jwt_link_expiration $JWT_EXPIRATION
drush vset -y jwt_link_key $JWT_KEY
drush vset -y jwt_link_url $JWT_URL


drush vset -y site_mail $SITE_EMAIL_FROM
drush vset -y swiftmailer_sender_email $SITE_EMAIL_FROM

emails_to_csv=$EMAILS_TO
emails_to_arr=(${EMAILS_TO//,/ })
emails_to_json=$(printf ', "%s"' ${emails_to_arr[@]})
emails_to_json="[${emails_to_json:2}]"

# support_email: used in callback, first is from second is to
support_email_json="[\"$SITE_EMAIL_FROM\", \"${emails_to_arr[0]}\"]"
drush vget --format=json --exact mmoda_settings |
    jq ".support_email = [${support_email_json}] " |
    drush vset --format=json --exact --yes mmoda_settings - 2>/dev/null # because we don't want to see all array in log

drush vset --format=json --exact --yes update_notify_emails $emails_to_json
drush vset --yes webform_default_from_address $SITE_EMAIL_FROM

for form_id in 383 392; do
    query="CREATE TEMPORARY TABLE webform_emails_tmp AS SELECT * FROM webform_emails WHERE nid=$form_id LIMIT 1;"
    query+="DELETE FROM webform_emails WHERE nid=$form_id;"
    for (( i=0; i<${#emails_to_arr[@]}; i++ )); do
        query+="UPDATE webform_emails_tmp SET eid=$((i+1)), email=\"${emails_to_arr[i]}\", from_address=\"$SITE_EMAIL_FROM\";"
        query+="INSERT INTO webform_emails SELECT * FROM webform_emails_tmp;"
    done

    drush sql-query "$query"
done

drush sql-query "DELETE FROM webform_emails WHERE nid=384 AND eid>1;"

drush vset --yes swiftmailer_smtp_host $swiftmailer_smtp_host
drush vset --yes swiftmailer_smtp_password $swiftmailer_smtp_password
drush vset --yes swiftmailer_smtp_port $swiftmailer_smtp_port
drush vset --yes swiftmailer_smtp_username $swiftmailer_smtp_username
drush vset --yes swiftmailer_smtp_encryption $swiftmailer_smtp_encryption

echo "{\"client_id\": \"$openid_client_id\", \"client_secret\": \"$openid_client_secret\", \"github_scopes\": \"user:email\"}" | 
    drush vset --yes --exact --format=json openid_connect_client_github -

if [ -f /backups/state-snapshot.sql ]; then
    echo run-sql /backups/state-snapshot.sql
else
    echo "No state-snapshot.sql found in /backups"
fi

drush cc -y all 