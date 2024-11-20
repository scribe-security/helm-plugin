#! /bin/bash
echo "Valint Helm Plugin"

# env
# ${HELM_BIN} list
set -x
VALINT_BIN="${HELM_PLUGIN_DIR}/valint"

# Initialize FLAGS as an empty string
FLAGS=""
BOM_FLAGS=""
CHART_NAME=""
TEMPLATE_FLAGS=""
PROVIDED_CHART_VERSION=""

if [[ -z "$TMP_DIR" ]]; then
  TMP_DIR=".tmp"
fi

# Loop through the arguments
while [ "$#" -gt 0 ]; do
  arg="$1"  # Get the first argument
  case "$arg" in
    "--glob")
      # Handle --glob flag
    #   FLAGS+=" --glob"
      ;;
    "--skip-pull")
        SKIP_PULL=true
        shift
      ;;
    "--values="*)
        TEMPLATE_FLAGS+=" $1"
        shift
      ;;
    "--values"*)
        TEMPLATE_FLAGS+=" $1 $2"
        shift 2
      ;;
    "--slsa")
      # Handle --skip-slsa flag
        ENABLE_SLSA=true
        shift
      ;;
    "--product-key="*)
        PRODUCT_KEY_FOUND=true
        FLAGS+=" $1"
        shift    
      ;;
    "--product-key"*)
        PRODUCT_KEY_FOUND=true
        FLAGS+=" $1 $2"
        shift 2
      ;;
    "--product-version="*)
        PRODUCT_VERSION_FOUND=true
        FLAGS+=" $1"
        shift   
      ;;
    "--product-version"*)
        PRODUCT_VERSION_FOUND=true
        FLAGS+=" $1 $2"
        shift 2
      ;;
    "--components="*)
        BOM_FLAGS+=" $1"
        shift    
      ;;
    "--components"*)
        BOM_FLAGS+=" $1 $2"    
        shift 2
      ;;
    "--format="*)
        FORMAT_FOUND=true
        FLAGS+=" $1"
        shift    
      ;;
    "--format"*)
        FORMAT_FOUND=true
        FLAGS+=" $1 $2"
        shift 2
      ;;
    "--version"*)
        PROVIDED_CHART_VERSION="$2"
        shift 2
      ;;
    "--"*"="*)
        FLAGS+=" $1"
        shift
      ;;
    "--"*)
        # If the next argument is not a flag, consider it as a value for --components
        FLAGS+=" $1 $2"
        shift 2 
      ;;
    "-"*)
        # If the next argument is not a flag, consider it as a value for --components
        FLAGS+=" $arg"
        shift
      ;;
    *)
     # If the argument doesn't start with "--", treat it as the chart name
      if [ -z "$CHART_NAME" ]; then
        CHART_NAME="$arg"
      else
        echo "Unknown option: $arg"
      fi
      shift
      ;;
      
  esac
done

get_chart_version() {  
  local chart_version=$($HELM_BIN search repo $CHART_NAME 2>/dev/null |  awk -v chart_name="$CHART_NAME" '$1 "~/"chart_name"/"{print $2}' | tail -1)

  if [ $? -eq 0 ] && [ "$chart_version" != "results" ]; then
    chart_version=${chart_version//\"}
    echo "$chart_version"
  else
    local chart_version=$(cat "$CHART_NAME/Chart.yaml" 2>/dev/null | grep "^version:" | awk '{print $2}')
    if [ $? -eq 0 ]; then
      chart_version=${chart_version//\"}
      echo "$chart_version"
    else
      echo ""
    fi 
  fi
}

get_app_version() {  
  local app_version=$($HELM_BIN search repo $CHART_NAME 2>/dev/null |  awk -v chart_name="$CHART_NAME" '$1 "~/"app_name"/"{print $3}' | tail -1)

  if [ $? -eq 0 ] && [ "$app_version" != "found" ]; then
    app_version=${app_version//\"}
    echo "$app_version"
  else
    app_version=$(cat "$CHART_NAME/Chart.yaml" | grep "^appVersion:" | awk '{print $2}')
    if [ $? -eq 0 ]; then
      app_version=${app_version//\"}
      echo "$app_version"
    else
      echo ""
    fi   fi
}

get_chart_name() {
  local chart_name=$($HELM_BIN search repo $CHART_NAME 2>/dev/null | awk -v chart_name="$CHART_NAME" '$1 "~/"chart_name"/"{print $1}')

  if [ $? -eq 0 ] && [ "$chart_name" != "No" ]; then
    CHART_NAME=${CHART_NAME//\"}
    echo "$CHART_NAME"
  else
    chart_name=$(cat "$CHART_NAME/Chart.yaml" 2>/dev/null | grep "^name:" | awk '{print $2}')
    if [ $? -eq 0 ]; then
      chart_name=${chart_name//\"}
      echo "$chart_name"
    else
      echo ""
    fi
  fi
}

if [[ $CHART_NAME == oci://* ]]; then
  echo "Early Pull setting"
  rm -rf $TMP_DIR
  $HELM_BIN pull $CHART_NAME --version $PROVIDED_CHART_VERSION --untar --untardir $TMP_DIR
  # CHART_NAME TAG oci://image:<tag>
  OCI_NAME=$(basename "$CHART_NAME")
  APP_VERSION=$PROVIDED_CHART_VERSION
  CHART_NAME=$TMP_DIR/$OCI_NAME #Overwrite name with local dir.
  CHART_VERSION=$PROVIDED_CHART_VERSION
else
  CHART_VERSION=$(get_chart_version)
  APP_VERSION=$(get_app_version)
  CHART_DEFINED_NAME=$(get_chart_name)
fi 



if [ -z "$CHART_VERSION" ]; then
  FLAGS+=" --label chart-version=$CHART_VERSION"
fi

if [ -z "$APP_VERSION" ]; then
  FLAGS+=" --label app-version=$APP_VERSION"
fi

if [ -z "$CHART_NAME" ]; then
  FLAGS+=" --label chart-name=$CHART_NAME"
fi

if [ -z "$FORMAT_FOUND" ]; then
  echo "Adding format '$FORMAT_FOUND'" 
  FLAGS+=" --format statement"
fi

if [ -z "$PRODUCT_KEY_FOUND" ]; then
  echo "Adding product key '$CHART_DEFINED_NAME'" 
  FLAGS+=" --product-key $CHART_DEFINED_NAME"
fi

if [ -z "$PRODUCT_VERSION_FOUND" ]; then
  echo "Adding product version '$APP_VERSION'" 
  FLAGS+=" --product-version $APP_VERSION"
fi

if [ "$PULL" = true ]; then
  echo "Pulling chart $CHART_NAME to $TMP_DIR..."
  if [[ $CHART_NAME == oci://* ]]; then
    echo "No need to PULL again FOR OCI"
    # $HELM_BIN pull $CHART_NAME $PROVIDED_CHART_VERSION --untar --untardir $TMP_DIR
  else
    $HELM_BIN pull $CHART_NAME $TMP_DIR
  fi
fi

if [ "$ENABLE_SLSA" = false ]; then
  echo "Enabling SLSA provenance creation for images..."
fi

echo "Collect evidence from '$CHART_NAME', With App version '$APP_VERSION' Chart version '$CHART_VERSION'..."

declare -a IMAGES=()
readarray -t IMAGES < <($HELM_BIN template $CHART_NAME $TEMPLATE_FLAGS | grep image: | sed -e 's/[ ]*image:[ ]*//' -e 's/"//g' -e "s/'//g" | sort -u)

echo "-------------------------------------"
if [ "$SKIP_PULL" = false ]; then
  for m in "${IMAGES[@]}"; do
    if command -v docker &> /dev/null; then
      echo "Prepull images"
      docker pull $m | true
    fi
  done
fi 

# Loop through IMAGES array
for m in "${IMAGES[@]}"; do
  # Run the command using VALINT_BIN and FLAGS
  echo "Collect evidence for '$m'..."
  echo valint bom "$m" $FLAGS $BOM_FLAGS
  "$VALINT_BIN" bom "$m" $FLAGS $BOM_FLAGS | true
  if [ "$ENABLE_SLSA" = true ]; then
    "$VALINT_BIN" slsa "$m" $FLAGS  | true
  fi
  echo "-------------------------------------"
done

