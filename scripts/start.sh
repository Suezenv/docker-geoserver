#!/bin/bash

source /scripts/functions.sh
source /scripts/env-data.sh
GS_VERSION=$(cat /scripts/geoserver_version.txt)
STABLE_PLUGIN_BASE_URL=$(cat /scripts/geoserver_gs_url.txt)

#web_cors
SETUP_LOCKFILE_DATA_INIT="${EXTRA_CONFIG_DIR}/.data_dir.lock"
if [[ ! -f "${SETUP_LOCKFILE_DATA_INIT}"  ]]; then
  cp -r /usr/local/tomcat/data/* ${GEOSERVER_DATA_DIR}
  touch ${SETUP_LOCKFILE_DATA_INIT}
fi

# Useful for development - We need a clean state of data directory
if [[ "${RECREATE_DATADIR}" =~ [Tt][Rr][Uu][Ee] ]]; then
  rm -rf "${GEOSERVER_DATA_DIR}"/*
fi

# install Font files in resources/fonts if they exists
if ls "${FONTS_DIR}"/*.ttf >/dev/null 2>&1; then
  cp -rf "${FONTS_DIR}"/*.ttf /usr/share/fonts/truetype/
fi

# Install opentype fonts
if ls "${FONTS_DIR}"/*.otf >/dev/null 2>&1; then
  cp -rf "${FONTS_DIR}"/*.otf /usr/share/fonts/opentype/
fi

# Add custom espg properties file or the default one
create_dir "${GEOSERVER_DATA_DIR}"/user_projections
create_dir "${GEOWEBCACHE_CACHE_DIR}"

setup_custom_crs

create_dir "${GEOSERVER_DATA_DIR}"/logs
export GEOSERVER_LOG_LEVEL
geoserver_logging

# Activate sample data
if [[ ${SAMPLE_DATA} =~ [Tt][Rr][Uu][Ee] ]]; then
  if [[ "$(ls -A $GEOSERVER_DATA_DIR)" ]];then
    echo "Data Dir "${GEOSERVER_DATA_DIR}" is already loaded"
  else
    cp -r "${CATALINA_HOME}"/data/* "${GEOSERVER_DATA_DIR}"
  fi
fi

# Recreate DISK QUOTA config, useful to change between H2 and jdbc and change connection or schema
if [[ "${RECREATE_DISKQUOTA}" =~ [Tt][Rr][Uu][Ee] ]]; then
  if [[ -f "${GEOWEBCACHE_CACHE_DIR}"/geowebcache-diskquota.xml ]]; then
    rm "${GEOWEBCACHE_CACHE_DIR}"/geowebcache-diskquota.xml
  fi
  if [[ -f "${GEOWEBCACHE_CACHE_DIR}"/geowebcache-diskquota-jdbc.xml ]]; then
    rm "${GEOWEBCACHE_CACHE_DIR}"/geowebcache-diskquota-jdbc.xml
  fi
fi

export DISK_QUOTA_FREQUENCY DISK_QUOTA_SIZE
if [[  ${DB_BACKEND} =~ [Pp][Oo][Ss][Tt][Gg][Rr][Ee][Ss] ]]; then
  postgres_ssl_setup
  export DISK_QUOTA_BACKEND=JDBC
  export SSL_PARAMETERS=${PARAMS}
  default_disk_quota_config
  jdbc_disk_quota_config

  echo -e "[Entrypoint] Checking PostgreSQL connection to see if diskquota tables are loaded: \033[0m"
  export PGPASSWORD="${POSTGRES_PASS}"
  postgres_ready_status ${HOST} ${POSTGRES_PORT} ${POSTGRES_USER} $POSTGRES_DB
  create_gwc_tile_tables ${HOST} ${POSTGRES_PORT} ${POSTGRES_USER} $POSTGRES_DB $POSTGRES_SCHEMA
else
  if [[ -f "${GEOWEBCACHE_CACHE_DIR}"/geowebcache-diskquota.xml ]];then
    rm "${GEOWEBCACHE_CACHE_DIR}"/geowebcache-diskquota.xml
  fi
  export DISK_QUOTA_BACKEND=H2
  default_disk_quota_config
fi

# Install stable plugins
if [[ ! -z "${STABLE_EXTENSIONS}" ]]; then
  if  [[ ${FORCE_DOWNLOAD_STABLE_EXTENSIONS} =~ [Tt][Rr][Uu][Ee] ]];then
      rm -rf /stable_plugins/*.zip
      for plugin in $(cat /stable_plugins/stable_plugins.txt); do
        approved_plugins_url="${STABLE_PLUGIN_BASE_URL}/${GS_VERSION}/extensions/geoserver-${GS_VERSION}-${plugin}.zip"
        download_extension "${approved_plugins_url}" "${plugin}" /stable_plugins
      done
      for ext in $(echo "${STABLE_EXTENSIONS}" | tr ',' ' '); do
        install_plugin /stable_plugins/ "${ext}"
    done
  else
    for ext in $(echo "${STABLE_EXTENSIONS}" | tr ',' ' '); do
        if [[ ! -f /stable_plugins/${ext}.zip ]]; then
          approved_plugins_url="${STABLE_PLUGIN_BASE_URL}/${GS_VERSION}/extensions/geoserver-${GS_VERSION}-${ext}.zip"
          download_extension "${approved_plugins_url}" "${ext}" /stable_plugins/
          install_plugin /stable_plugins/ "${ext}"
        else
          install_plugin /stable_plugins/ "${ext}"
        fi

    done
  fi
fi

if [[ ${ACTIVATE_ALL_STABLE_EXTENSIONS} =~ [Tt][Rr][Uu][Ee] ]];then
  pushd /stable_plugins/ || exit
  for val in *.zip; do
      ext=${val%.*}
      install_plugin /stable_plugins/ "${ext}"
  done
  pushd "${GEOSERVER_HOME}" || exit
fi


# Function to install community extensions
export S3_SERVER_URL S3_USERNAME S3_PASSWORD
# Pass an additional startup argument i.e -Ds3.properties.location=${GEOSERVER_DATA_DIR}/s3.properties
s3_config

# Install community modules plugins
if [[ ! -z ${COMMUNITY_EXTENSIONS} ]]; then
  if  [[ ${FORCE_DOWNLOAD_COMMUNITY_EXTENSIONS} =~ [Tt][Rr][Uu][Ee] ]];then
    rm -rf /community_plugins/*.zip
    for plugin in $(cat /community_plugins/community_plugins.txt); do
      community_plugins_url="https://build.geoserver.org/geoserver/${GS_VERSION:0:5}x/community-latest/geoserver-${GS_VERSION:0:4}-SNAPSHOT-${plugin}.zip"
      download_extension "${community_plugins_url}" "${plugin}" /community_plugins
    done
    for ext in $(echo "${COMMUNITY_EXTENSIONS}" | tr ',' ' '); do
        install_plugin /community_plugins "${ext}"
    done
  else
    for ext in $(echo "${COMMUNITY_EXTENSIONS}" | tr ',' ' '); do
        if [[ ! -f /community_plugins/${ext}.zip ]]; then
          community_plugins_url="https://build.geoserver.org/geoserver/${GS_VERSION:0:5}x/community-latest/geoserver-${GS_VERSION:0:4}-SNAPSHOT-${ext}.zip"
          download_extension "${community_plugins_url}" "${ext}" /community_plugins
          install_plugin /community_plugins "${ext}"
        else
          install_plugin /community_plugins "${ext}"
        fi
    done
  fi
fi


if [[ ${ACTIVATE_ALL_COMMUNITY_EXTENSIONS} =~ [Tt][Rr][Uu][Ee] ]];then
   pushd /community_plugins/ || exit
    for val in *.zip; do
        ext=${val%.*}
        install_plugin /community_plugins "${ext}"
    done
    pushd "${GEOSERVER_HOME}" || exit
fi

# Setup clustering
set_vars
export  READONLY CLUSTER_DURABILITY BROKER_URL EMBEDDED_BROKER TOGGLE_MASTER TOGGLE_SLAVE BROKER_URL
export CLUSTER_CONFIG_DIR MONITOR_AUDIT_PATH CLUSTER_LOCKFILE INSTANCE_STRING
create_dir "${MONITOR_AUDIT_PATH}"

if [[ ${CLUSTERING} =~ [Tt][Rr][Uu][Ee] ]]; then
  ext=jms-cluster-plugin
  if  [[ ${FORCE_DOWNLOAD_COMMUNITY_EXTENSIONS} =~ [Tt][Rr][Uu][Ee] ]];then
    if [[  -f /community_plugins/${ext}.zip ]]; then
      rm -rf /community_plugins/${ext}.zip
    fi
    community_plugins_url="https://build.geoserver.org/geoserver/${GS_VERSION:0:5}x/community-latest/geoserver-${GS_VERSION:0:4}-SNAPSHOT-${ext}.zip"
    download_extension "${community_plugins_url}" ${ext} /community_plugins
    install_plugin /community_plugins ${ext}
  else
    if [[ ! -f /community_plugins/${ext}.zip ]]; then
      community_plugins_url="https://build.geoserver.org/geoserver/${GS_VERSION:0:5}x/community-latest/geoserver-${GS_VERSION:0:4}-SNAPSHOT-${ext}.zip"
      download_extension "${community_plugins_url}" ${ext} /community_plugins
      install_plugin /community_plugins ${ext}
    else
      install_plugin /community_plugins ${ext}
    fi

  fi

  if [[ ! -f $CLUSTER_LOCKFILE ]]; then
      if [[ -z "${EXISTING_DATA_DIR}" ]]; then
          create_dir "${CLUSTER_CONFIG_DIR}"
      fi

      if [[  ${DB_BACKEND} =~ [Pp][Oo][Ss][Tt][Gg][Rr][Ee][Ss] ]];then
        postgres_ssl_setup
        export SSL_PARAMETERS=${PARAMS}
      fi
      broker_xml_config
      touch "${CLUSTER_LOCKFILE}"
  fi
  # setup clustering if it's not already defined in an existing data directory
  if [[ -z "${EXISTING_DATA_DIR}" ]]; then
      cluster_config
      broker_config
  fi


fi

export REQUEST_TIMEOUT PARALLEL_REQUEST GETMAP REQUEST_EXCEL SINGLE_USER GWC_REQUEST WPS_REQUEST
# Setup control flow properties
setup_control_flow

if [[ "${TOMCAT_EXTRAS}" =~ [Tt][Rr][Uu][Ee] ]]; then
    unzip -qq /tomcat_apps.zip -d /tmp/ &&
    cp -r  /tmp/tomcat_apps/webapps.dist/* "${CATALINA_HOME}"/webapps/ &&
    rm -r /tmp/tomcat_apps
    if [[ ${POSTGRES_JNDI} =~ [Ff][Aa][Ll][Ss][Ee] ]]; then
      if [[ -f ${EXTRA_CONFIG_DIR}/context.xml  ]]; then
        envsubst < ${EXTRA_CONFIG_DIR}/context.xml > "${CATALINA_HOME}"/webapps/manager/META-INF/context.xml
      else
        cp /build_data/context.xml "${CATALINA_HOME}"/webapps/manager/META-INF/
        sed -i -e '19,36d' "${CATALINA_HOME}"/webapps/manager/META-INF/context.xml
      fi
    fi
    if [[ -z ${TOMCAT_PASSWORD} ]]; then
        generate_random_string 18
        export TOMCAT_PASSWORD=${RAND}
        echo -e "[Entrypoint] GENERATED tomcat  PASSWORD: \e[1;31m $TOMCAT_PASSWORD \033[0m"
    else
       export TOMCAT_PASSWORD=${TOMCAT_PASSWORD}
    fi
    # Setup tomcat apps manager
    export TOMCAT_USER
    tomcat_user_config
else
    delete_folder "${CATALINA_HOME}"/webapps/ROOT &&
    delete_folder "${CATALINA_HOME}"/webapps/docs &&
    delete_folder "${CATALINA_HOME}"/webapps/examples &&
    delete_folder "${CATALINA_HOME}"/webapps/host-manager &&
    delete_folder "${CATALINA_HOME}"/webapps/manager

    if [[ "${ROOT_WEBAPP_REDIRECT}" =~ [Tt][Rr][Uu][Ee] ]]; then
        mkdir "${CATALINA_HOME}"/webapps/ROOT
        cat /build_data/index.jsp | sed "s@/geoserver/@/${GEOSERVER_CONTEXT_ROOT}/@g" > "${CATALINA_HOME}"/webapps/ROOT/index.jsp
    fi
fi

SETUP_LOCKFILE="${EXTRA_CONFIG_DIR}/.first_time_hash.lock"
if [[ -z "${EXISTING_DATA_DIR}" ]]; then
  if [[ ! -f "${SETUP_LOCKFILE}"  ]]; then
cat > ${GEOSERVER_DATA_DIR}/security/usergroup/default/users.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<userRegistry version="1.0" xmlns="http://www.geoserver.org/security/users">
    <users>
        <user enabled="true" name="admin" password="digest1:D9miJH/hVgfxZJscMafEtbtliG0ROxhLfsznyWfG38X2pda2JOSV4POi55PQI4tw"/>
    </users>
    <groups/>
</userRegistry>
EOF
  fi
  /scripts/update_passwords.sh
fi

