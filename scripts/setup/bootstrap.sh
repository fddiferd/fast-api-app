#!/bin/bash
set -e

# Function to run a command with a timeout using a background process
# This is portable and works on macOS and Linux without requiring GNU timeout
run_with_timeout() {
  local cmd="$1"
  local timeout_seconds="${2:-30}"
  local message="${3:-Command timed out}"
  
  # Run the command in the background
  eval "$cmd" &
  local cmd_pid=$!
  
  # Monitor for timeout
  local count=0
  while [ $count -lt $timeout_seconds ]; do
    # Check if process is still running
    if ! ps -p $cmd_pid > /dev/null; then
      # Process completed
      wait $cmd_pid
      return $?
    fi
    sleep 1
    count=$((count + 1))
  done
  
  # If we got here, the command timed out
  echo "⚠️ $message after $timeout_seconds seconds"
  kill -9 $cmd_pid 2>/dev/null || true
  wait $cmd_pid 2>/dev/null || true
  return 124 # Standard timeout exit code
}

echo "===================================================================="
echo "            GCP Project Bootstrap Tool                               "
echo "===================================================================="

#==========================================================================
# SECTION 1: CONFIGURATION LOADING
#==========================================================================
echo
echo "LOADING CONFIGURATION"
echo "---------------------"

# Read environment variables from .env file
echo "Loading environment variables..."
source .env
GCP_BILLING_ACCOUNT_ID=${GCP_BILLING_ACCOUNT_ID:-}
DEV_SCHEMA_NAME=${DEV_SCHEMA_NAME:-}
MODE=${MODE:-dev}
SKIP_TERRAFORM=${SKIP_TERRAFORM:-false}
SKIP_AR_CHECK=${SKIP_AR_CHECK:-false}
SKIP_API_ENABLE=${SKIP_API_ENABLE:-false}

# Load config values using a more portable approach for macOS
echo "Loading project configuration..."

# Function to extract values from config file (macOS compatible)
extract_config_value() {
    local key=$1
    local value
    value=$(grep "^$key: str = " config | sed -E "s/^$key: str = ['\"](.*)['\"].*$/\1/")
    echo "$value"
}

# Function to ensure project ID doesn't exceed GCP's 30-character limit
ensure_valid_project_id() {
    local project_id=$1
    local max_length=30
    
    # Check if project ID exceeds max length
    if [ ${#project_id} -gt $max_length ]; then
        echo "⚠️ Warning: Project ID '$project_id' exceeds $max_length characters"
        # Truncate to max_length, preserving important parts
        local truncated
        if [[ "$project_id" == *"-dev-"* ]]; then
            # For dev projects: Keep "-dev-username" suffix, truncate the base
            local username=$(echo "$project_id" | sed 's/.*-dev-\(.*\)/\1/')
            local base=$(echo "$project_id" | sed 's/\(.*\)-dev-.*/\1/')
            local remaining=$((max_length - ${#username} - 5)) # 5 for "-dev-"
            
            if [ $remaining -lt 5 ]; then
                # Username too long, must truncate both
                truncated="${base:0:10}-dev-${username:0:14}"
            else
                # Truncate only the base
                truncated="${base:0:$remaining}-dev-$username"
            fi
        else
            # For staging/prod, just truncate
            truncated="${project_id:0:$max_length}"
        fi
        
        echo "Project ID truncated to: $truncated"
        echo "$truncated"
    else
        echo "$project_id"
    fi
}

GCP_PROJECT_ID=$(extract_config_value "gcp_project_id")
SERVICE_NAME=$(extract_config_value "service_name")
REPO_NAME=$(extract_config_value "repo_name")
REGION=$(extract_config_value "region")

# Check if PROJECT_ID from config is available
if [ -z "$GCP_PROJECT_ID" ]; then
  echo "❌ Error: gcp_project_id is not set in config file"
  exit 1
fi

# Always use the PROJECT_ID from config
PROJECT_ID="$GCP_PROJECT_ID"

if [ -z "$MODE" ]; then
  echo "⚠️ MODE not set in .env, defaulting to dev"
  MODE="dev"
fi

if [ "$MODE" == "dev" ] && [ -z "$DEV_SCHEMA_NAME" ]; then
  echo "❌ Error: DEV_SCHEMA_NAME not set in .env, required for dev mode"
  exit 1
fi

#==========================================================================
# SECTION 2: PROJECT SETUP
#==========================================================================
echo
echo "PROJECT SETUP"
echo "-------------"

# Project naming based on mode
if [ "$MODE" == "dev" ]; then
  # Convert to lowercase using tr (macOS compatible)
  PROJECT_ID_LOWER=$(echo "$PROJECT_ID" | tr '[:upper:]' '[:lower:]')
  DEV_SCHEMA_LOWER=$(echo "$DEV_SCHEMA_NAME" | tr '[:upper:]' '[:lower:]')
  PROJECT_NAME="${PROJECT_ID_LOWER}-dev-${DEV_SCHEMA_LOWER}"
  # Ensure valid project ID (within 30 characters)
  PROJECT_NAME=$(ensure_valid_project_id "$PROJECT_NAME")
elif [ "$MODE" == "staging" ]; then
  PROJECT_ID_LOWER=$(echo "$PROJECT_ID" | tr '[:upper:]' '[:lower:]')
  PROJECT_NAME="${PROJECT_ID_LOWER}-staging"
  # Ensure valid project ID (within 30 characters)
  PROJECT_NAME=$(ensure_valid_project_id "$PROJECT_NAME")
elif [ "$MODE" == "prod" ]; then
  PROJECT_ID_LOWER=$(echo "$PROJECT_ID" | tr '[:upper:]' '[:lower:]')
  PROJECT_NAME="${PROJECT_ID_LOWER}-prod"
  # Ensure valid project ID (within 30 characters)
  PROJECT_NAME=$(ensure_valid_project_id "$PROJECT_NAME")
else
  echo "❌ Error: Invalid MODE: $MODE. Must be dev, staging, or prod."
  exit 1
fi

echo "Bootstrapping project: $PROJECT_NAME (Environment: $MODE)"

# Check active gcloud configuration
ACTIVE_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [ "$ACTIVE_PROJECT" != "$PROJECT_NAME" ]; then
  echo "⚠️ WARNING: Your active gcloud configuration is using project: $ACTIVE_PROJECT"
  echo "  But this script will deploy to: $PROJECT_NAME"
  read -p "  Do you want to switch your gcloud config to $PROJECT_NAME? (y/n) " SWITCH_PROJECT
  
  if [[ $SWITCH_PROJECT == "y" || $SWITCH_PROJECT == "Y" ]]; then
    echo "Switching gcloud configuration to $PROJECT_NAME..."
    gcloud config set project $PROJECT_NAME
    echo "✅ Active project switched to $PROJECT_NAME"
  else
    echo "Continuing with current configuration. Commands will target $PROJECT_NAME explicitly."
    echo "Note that any manual gcloud commands you run will still target $ACTIVE_PROJECT unless you specify --project=$PROJECT_NAME"
  fi
else
  echo "✅ Active gcloud configuration matches target project: $PROJECT_NAME"
fi

echo "Checking if project $PROJECT_NAME exists..."

# Check if project exists
if gcloud projects describe "$PROJECT_NAME" &> /dev/null; then
  echo "✅ Project $PROJECT_NAME already exists."
  
  # Check permissions
  echo "Checking permissions..."
  if gcloud projects get-iam-policy "$PROJECT_NAME" &> /dev/null; then
    echo "✅ You have sufficient IAM permissions on this project."
    
    # Get the current user
    CURRENT_USER=$(gcloud config get-value account)
    
    if [ -z "$CURRENT_USER" ]; then
      echo "❌ Error: Could not determine current user. Please run 'gcloud auth login' first."
      exit 1
    fi
      
    # Check if custom developer role exists already
    ROLE_EXISTS=$(gcloud iam roles list --project=$PROJECT_NAME --filter="name:projects/$PROJECT_NAME/roles/developer" --format="value(name)" 2>/dev/null || echo "")
    
    if [ -z "$ROLE_EXISTS" ]; then
      echo "Creating custom developer role..."
      # Create temporary file for role definition
      cat > /tmp/developer-role.yaml << EOF
title: Developer
description: Custom role for application developers
stage: GA
includedPermissions:
- artifactregistry.repositories.create
- artifactregistry.repositories.get
- artifactregistry.repositories.list
- artifactregistry.repositories.uploadArtifacts
- artifactregistry.tags.create
- artifactregistry.tags.get
- artifactregistry.tags.list
- artifactregistry.tags.update
- run.services.create
- run.services.get
- run.services.list
- run.services.update
- run.services.setIamPolicy
- run.executions.get
- run.executions.list
- run.locations.list
- run.operations.get
- run.routes.invoke
- logging.logs.list
- logging.logEntries.list
- logging.logEntries.create
- logging.logServiceIndexes.list
- logging.logServices.list
- storage.objects.create
- storage.objects.delete
- storage.objects.get
- storage.objects.list
- storage.objects.update
EOF
      
      # Create custom role
      gcloud iam roles create developer --project=$PROJECT_NAME --file=/tmp/developer-role.yaml
      rm /tmp/developer-role.yaml
      echo "✅ Custom developer role created."
    else
      echo "✅ Custom developer role already exists."
    fi
    
    # Check if user has the developer role
    HAS_ROLE=$(gcloud projects get-iam-policy $PROJECT_NAME --format=json | \
      jq -r ".bindings[] | select(.role == \"projects/$PROJECT_NAME/roles/developer\") | .members[] | select(. == \"user:$CURRENT_USER\")" 2>/dev/null || echo "")
    
    if [ -z "$HAS_ROLE" ]; then
      echo "Granting developer role to $CURRENT_USER..."
      gcloud projects add-iam-policy-binding $PROJECT_NAME \
        --member="user:$CURRENT_USER" \
        --role="projects/$PROJECT_NAME/roles/developer"
      echo "✅ Developer role assigned."
    else
      echo "✅ User already has developer role."
      
      # Skip Artifact Registry check if SKIP_AR_CHECK is true
      if [ "$SKIP_AR_CHECK" = "true" ]; then
        echo "⚠️ Skipping Artifact Registry check (SKIP_AR_CHECK=true)"
        echo "✅ Assuming Artifact Registry permissions are sufficient"
      else
        echo "Checking Artifact Registry access..."
        # Use our custom timeout function instead of the timeout command
        if run_with_timeout "gcloud artifacts repositories list --project=\"$PROJECT_NAME\" --location=\"$REGION\" &> /dev/null" 10 "Artifact Registry check"; then
          echo "✅ You have Artifact Registry permissions."
        else
          echo "⚠️ Artifact Registry check timed out or failed. Adding permissions anyway..."
          
          # Grant Artifact Registry permissions directly in case the custom role isn't sufficient
          echo "Granting Artifact Registry Writer role to $CURRENT_USER..."
          gcloud projects add-iam-policy-binding "$PROJECT_NAME" \
            --member="user:$CURRENT_USER" \
            --role="roles/artifactregistry.writer" || echo "❗ Could not add IAM binding, but continuing..."
        fi
      fi
    fi
  else
    echo "❌ Error: You don't have sufficient permissions on this project."
    exit 1
  fi
else
  echo "Project doesn't exist. A new project needs to be created."
  
  # Now check for billing account only if we need to create a new project
  if [ -z "$GCP_BILLING_ACCOUNT_ID" ]; then
    echo "❌ Error: GCP_BILLING_ACCOUNT_ID is not set in .env"
    echo "  This is required to create a new project."
    echo "  If you're joining an existing project, make sure the project ID is correct."
    exit 1
  fi
  
  echo "Checking billing account..."
  
  # Check if billing account exists and we have access to it
  if gcloud billing accounts list --filter="ACCOUNT_ID:$GCP_BILLING_ACCOUNT_ID" --format="value(ACCOUNT_ID)" | grep -q "$GCP_BILLING_ACCOUNT_ID"; then
    echo "✅ Billing account exists. Creating project $PROJECT_NAME..."
    gcloud projects create "$PROJECT_NAME" --name="$PROJECT_NAME"
    
    echo "Linking billing account to project..."
    gcloud billing projects link "$PROJECT_NAME" --billing-account="$GCP_BILLING_ACCOUNT_ID"
    
    # Get the current user
    CURRENT_USER=$(gcloud config get-value account)
    
    # First grant basic editor permissions needed for next steps
    echo "Granting basic editor permissions to $CURRENT_USER..."
    gcloud projects add-iam-policy-binding "$PROJECT_NAME" \
      --member="user:$CURRENT_USER" \
      --role="roles/editor"
    
    # Create custom developer role
    echo "Creating custom developer role..."
    # Create temporary file for role definition
    cat > /tmp/developer-role.yaml << EOF
title: Developer
description: Custom role for application developers
stage: GA
includedPermissions:
- artifactregistry.repositories.create
- artifactregistry.repositories.get
- artifactregistry.repositories.list
- artifactregistry.repositories.uploadArtifacts
- artifactregistry.tags.create
- artifactregistry.tags.get
- artifactregistry.tags.list
- artifactregistry.tags.update
- run.services.create
- run.services.get
- run.services.list
- run.services.update
- run.services.setIamPolicy
- run.executions.get
- run.executions.list
- run.locations.list
- run.operations.get
- run.routes.invoke
- logging.logs.list
- logging.logEntries.list
- logging.logEntries.create
- logging.logServiceIndexes.list
- logging.logServices.list
- storage.objects.create
- storage.objects.delete
- storage.objects.get
- storage.objects.list
- storage.objects.update
EOF

    # Create custom role
    gcloud iam roles create developer --project=$PROJECT_NAME --file=/tmp/developer-role.yaml
    rm /tmp/developer-role.yaml
    
    # Assign developer role to current user
    echo "Granting developer role to $CURRENT_USER..."
    gcloud projects add-iam-policy-binding $PROJECT_NAME \
      --member="user:$CURRENT_USER" \
      --role="projects/$PROJECT_NAME/roles/developer"
    
    echo "✅ Custom developer role created and assigned."
  else
    echo "❌ Error: Could not access billing account $GCP_BILLING_ACCOUNT_ID"
    echo "This could be due to:"
    echo "  1. The billing account ID is incorrect"
    echo "  2. You need to authenticate with sufficient permissions"
    echo ""
    echo "Try running: gcloud auth login"
    echo "Then verify you have access with: gcloud billing accounts list"
    exit 1
  fi
fi

#==========================================================================
# SECTION 3: API ENABLEMENT
#==========================================================================
echo
echo "ENABLING APIS"
echo "-------------"

# Skip API enablement if SKIP_API_ENABLE is true
if [ "$SKIP_API_ENABLE" = "true" ]; then
  echo "⚠️ Skipping API enablement (SKIP_API_ENABLE=true)"
  echo "❗ Note: APIs required for this project may not be enabled"
  echo "   You can manually enable them with: gcloud services enable artifactregistry.googleapis.com cloudbuild.googleapis.com run.googleapis.com containerregistry.googleapis.com --project=$PROJECT_NAME"
  
  # If we can't enable APIs, we definitely should skip Terraform
  SKIP_TERRAFORM=true
  echo "⚠️ Setting SKIP_TERRAFORM=true due to API enablement being skipped"
else
  echo "Enabling required APIs for $PROJECT_NAME..."
  # Use our custom timeout function
  if run_with_timeout "gcloud services enable artifactregistry.googleapis.com cloudbuild.googleapis.com run.googleapis.com containerregistry.googleapis.com --project=\"$PROJECT_NAME\"" 60 "API enablement"; then
    echo "✅ APIs enabled successfully"
  else
    echo "⚠️ API enablement failed or timed out. Setting SKIP_TERRAFORM=true"
    SKIP_TERRAFORM=true
  fi
fi

#==========================================================================
# SECTION 4: TERRAFORM CONFIGURATION
#==========================================================================
echo
echo "TERRAFORM CONFIGURATION"
echo "-----------------------"

# Get GitHub repository information for Terraform
echo "Setting up Terraform configuration..."

# Instead of using git commands, use the config values
GITHUB_OWNER=$(extract_config_value "github_owner")
REPO_NAME=$(extract_config_value "repo_name")
USER_EMAIL=$(git config --get user.email)

# Prepare Terraform variables
echo "Setting up Terraform configuration..."
echo "Note: terraform.tfvars files are gitignored and will be regenerated on each bootstrap run"

# Check if project exists
if gcloud projects describe "$PROJECT_NAME" &> /dev/null; then
  # For existing projects, we'll set a flag to skip unnecessary Terraform operations
  EXISTING_PROJECT="true"
else
  EXISTING_PROJECT="false"
fi

# Create terraform.tfvars file for bootstrap
mkdir -p terraform/bootstrap
cat > terraform/bootstrap/terraform.tfvars << EOF
environment = "$MODE"
billing_account_id = "$GCP_BILLING_ACCOUNT_ID"
project_ids = {
  $MODE = "$PROJECT_NAME"
}
region = "$REGION"
service_name = "$SERVICE_NAME"
repo_name = "$REPO_NAME"
skip_billing_setup = $EXISTING_PROJECT
EOF
echo "✅ Bootstrap Terraform variables created"

# Create terraform.tfvars file for CICD
mkdir -p terraform/cicd
cat > terraform/cicd/terraform.tfvars << EOF
environment = "$MODE"
project_id = "$PROJECT_NAME"
github_owner = "$GITHUB_OWNER"
github_repo = "$REPO_NAME"
user_email = "$USER_EMAIL"
region = "$REGION"
service_name = "$SERVICE_NAME"
repo_name = "$REPO_NAME"
skip_resource_creation = $EXISTING_PROJECT
EOF
echo "✅ CICD Terraform variables created"

#==========================================================================
# SECTION 5: TERRAFORM DEPLOYMENT (OPTIONAL)
#==========================================================================

# Check if we should skip Terraform deployment
if [ "${SKIP_TERRAFORM:-true}" == "true" ]; then
  echo
  echo "Skipping Terraform deployment (SKIP_TERRAFORM=true)"
  echo "To run Terraform deployment, set SKIP_TERRAFORM=false in .env"
  echo "or run: SKIP_TERRAFORM=false ./scripts/setup/bootstrap.sh"
else
  echo
  echo "DEPLOYING INFRASTRUCTURE"
  echo "------------------------"
  
  # Before Terraform, create proper service accounts for the project
  echo
  echo "SETTING UP SERVICE ACCOUNTS"
  echo "----------------------------"

  # Create proper service account for the project
  echo "Creating service account for $PROJECT_NAME..."
  SA_NAME="cloudrun-${MODE}-sa"
  SA_EMAIL="${SA_NAME}@${PROJECT_NAME}.iam.gserviceaccount.com"
  EXISTING_SA=$(gcloud iam service-accounts describe $SA_EMAIL --project=$PROJECT_NAME 2>/dev/null || echo "")

  if [[ -z "$EXISTING_SA" ]]; then
    echo "Creating service account $SA_NAME..."
    gcloud iam service-accounts create $SA_NAME --project=$PROJECT_NAME --display-name="Cloud Run Service Account for $MODE" || {
      echo "⚠️ Could not create service account $SA_NAME. You may need to create it manually."
      echo "Command to create manually: gcloud iam service-accounts create $SA_NAME --project=$PROJECT_NAME"
    }
  else
    echo "✅ Service account $SA_EMAIL already exists"
  fi

  # Ensure the Cloud Run service account has the necessary permissions
  echo "Ensuring Cloud Run service account has proper permissions..."
  # Add specific Cloud Run roles that have been causing issues
  gcloud projects add-iam-policy-binding $PROJECT_NAME --member="serviceAccount:${SA_EMAIL}" --role="roles/run.developer" --condition=None
  gcloud projects add-iam-policy-binding $PROJECT_NAME --member="serviceAccount:${SA_EMAIL}" --role="roles/run.invoker" --condition=None
  # Admin role is already in Terraform but add it here too for immediate effect
  gcloud projects add-iam-policy-binding $PROJECT_NAME --member="serviceAccount:${SA_EMAIL}" --role="roles/run.admin" --condition=None
  
  # Add serviceAccountUser permissions to allow the service account to act as itself
  echo "Adding serviceAccountUser permissions for service accounts..."
  # Allow the service account to act as itself
  gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/iam.serviceAccountUser" \
    --project=$PROJECT_NAME
    
  # Allow the Cloud Build service account to act as the Cloud Run service account
  PROJECT_NUMBER=$(gcloud projects describe $PROJECT_NAME --format="value(projectNumber)")
  CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
  gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
    --member="serviceAccount:${CLOUDBUILD_SA}" \
    --role="roles/iam.serviceAccountUser" \
    --project=$PROJECT_NAME
  
  # Ensure proper permissions for Cloud Build
  echo "Ensuring proper permissions for Cloud Build service account..."
  CLOUDBUILD_SA=$(gcloud projects get-iam-policy $PROJECT_NAME --format="value(bindings.members)" | grep cloudbuild.gserviceaccount || echo "")
  if [[ -z "$CLOUDBUILD_SA" ]]; then
    echo "⚠️ Cloud Build service account not found. Creating permissions manually..."
    PROJECT_NUMBER=$(gcloud projects describe $PROJECT_NAME --format="value(projectNumber)")
    CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
    
    # Add key permissions
    echo "Adding logging permissions to Cloud Build service account..."
    gcloud projects add-iam-policy-binding $PROJECT_NAME --member="serviceAccount:${CLOUDBUILD_SA}" --role="roles/logging.logWriter"
    
    echo "Adding Artifact Registry permissions to Cloud Build service account..."
    gcloud projects add-iam-policy-binding $PROJECT_NAME --member="serviceAccount:${CLOUDBUILD_SA}" --role="roles/artifactregistry.writer"
  else
    echo "✅ Cloud Build service account found, ensuring it has permissions..."
    PROJECT_NUMBER=$(gcloud projects describe $PROJECT_NAME --format="value(projectNumber)")
    CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
    
    # Add key permissions regardless (idempotent)
    gcloud projects add-iam-policy-binding $PROJECT_NAME --member="serviceAccount:${CLOUDBUILD_SA}" --role="roles/logging.logWriter"
    gcloud projects add-iam-policy-binding $PROJECT_NAME --member="serviceAccount:${CLOUDBUILD_SA}" --role="roles/artifactregistry.writer"
  fi

  # Check for existing Artifact Registry repository
  REPO_EXISTS=$(gcloud artifacts repositories describe "$REPO_NAME" --project="$PROJECT_NAME" --location="$REGION" 2>/dev/null || echo "")

  if [[ -n "$REPO_EXISTS" ]]; then
    echo "✅ Artifact Registry repository $REPO_NAME already exists"
    
    # Add repository-level permissions
    echo "Adding repository-level permissions for Cloud Build service account..."
    gcloud artifacts repositories add-iam-policy-binding $REPO_NAME --location=$REGION --member="serviceAccount:${CLOUDBUILD_SA}" --role=roles/artifactregistry.writer --project=$PROJECT_NAME || echo "⚠️ Could not add Cloud Build permissions to repository, will try again later"
    
    echo "Adding repository-level permissions for Cloud Run service account..."
    gcloud artifacts repositories add-iam-policy-binding $REPO_NAME --location=$REGION --member="serviceAccount:${SA_EMAIL}" --role=roles/artifactregistry.writer --project=$PROJECT_NAME || echo "⚠️ Could not add Cloud Run permissions to repository, will try again later"
    
    # Add a note to the Terraform variables file to avoid recreation
    echo "# Repository already exists - creation will be skipped" >> terraform/bootstrap/terraform.tfvars
  else
    echo "Creating Artifact Registry repository..."
    # Use our custom timeout function instead of the timeout command
    if run_with_timeout "gcloud artifacts repositories create $REPO_NAME --repository-format=docker --location=$REGION --description=\"Docker repository for $REPO_NAME\" --project=$PROJECT_NAME" 30 "Repository creation"; then
      echo "✅ Repository created successfully"
    else
      echo "⚠️ Could not create repository, continuing anyway. Repository will be created during deployment if needed."
    fi
    
    # If creation was successful, add permissions
    if [[ -n "$(gcloud artifacts repositories describe "$REPO_NAME" --project="$PROJECT_NAME" --location="$REGION" 2>/dev/null || echo "")" ]]; then
      echo "✅ Repository created successfully, adding permissions..."
      gcloud artifacts repositories add-iam-policy-binding $REPO_NAME --location=$REGION --member="serviceAccount:${CLOUDBUILD_SA}" --role=roles/artifactregistry.writer --project=$PROJECT_NAME || echo "⚠️ Could not add Cloud Build permissions to repository"
      gcloud artifacts repositories add-iam-policy-binding $REPO_NAME --location=$REGION --member="serviceAccount:${SA_EMAIL}" --role=roles/artifactregistry.writer --project=$PROJECT_NAME || echo "⚠️ Could not add Cloud Run permissions to repository"
    else
      # Let Terraform create the repository
      echo "# Repository doesn't exist - will be created by Terraform" >> terraform/bootstrap/terraform.tfvars
    fi
  fi

  # Run the Firestore setup script
  echo "Running Firestore setup script..."
  ./scripts/setup/firestore_setup.sh

  # Initialize and apply Terraform for bootstrap
  echo "Running Terraform bootstrap..."
  cd terraform/bootstrap
  terraform init

  # If this is an existing project, only apply if explicitly requested
  if [[ "$EXISTING_PROJECT" == "true" ]]; then
    echo "Project already exists, skipping bootstrap Terraform apply."
    echo "To force apply, run: cd terraform/bootstrap && terraform apply"
  else
    # Run apply with auto-approve for new projects
    terraform apply -auto-approve || {
      echo "⚠️ Terraform apply had errors, but we'll continue if non-critical."
      # Check if we can still deploy the application
      if [[ -z "$(gcloud artifacts repositories list --project=$PROJECT_NAME --location=$REGION --filter="name:$REPO_NAME" --format="value(name)" 2>/dev/null)" ]]; then
        echo "❌ Error: Critical infrastructure is missing, cannot continue."
        echo "Please check the Terraform errors and try again."
        exit 1
      else
        echo "✅ Critical infrastructure exists, continuing with deployment."
      fi
    }
  fi

  cd ../..
  echo "✅ Bootstrap Terraform completed"

  # Firebase Setup Guidance
  echo 
  echo "FIREBASE SETUP"
  echo "-------------"
  echo "For Firebase integration, you need to set up Firebase in the Google Cloud Console:"
  echo "Steps:"
  echo "1. Go to: https://console.firebase.google.com/project/$PROJECT_NAME/overview"
  echo "2. Complete the Firebase setup if not already done"
  echo "3. Create a service account key for Firebase Admin SDK if needed"
  echo "4. Place the key file in service_accounts/firebase-${MODE}.json"

  # Check if Firebase service account key exists
  if [[ ! -f "service_accounts/firebase-${MODE}.json" ]]; then
    echo
    echo "⚠️ Firebase service account key not found. You need to create one."
    echo "Would you like to open Firebase Console now? (y/n)"
    read -r OPEN_FIREBASE
    if [[ "$OPEN_FIREBASE" == "y" || "$OPEN_FIREBASE" == "Y" ]]; then
      # Try to open URL using appropriate command based on OS
      if [[ "$OSTYPE" == "darwin"* ]]; then
        open "https://console.firebase.google.com/project/$PROJECT_NAME/settings/serviceaccounts/adminsdk"
      elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        xdg-open "https://console.firebase.google.com/project/$PROJECT_NAME/settings/serviceaccounts/adminsdk" &>/dev/null
      else
        echo "Please manually visit: https://console.firebase.google.com/project/$PROJECT_NAME/settings/serviceaccounts/adminsdk"
      fi
      
      echo "Once you've downloaded the key file, please rename it to firebase-${MODE}.json"
      echo "and place it in the service_accounts directory."
      echo
      echo "Have you completed this step? (y/n)"
      read -r FIREBASE_KEY_DONE
      if [[ "$FIREBASE_KEY_DONE" != "y" && "$FIREBASE_KEY_DONE" != "Y" ]]; then
        echo "⚠️ You'll need to create the Firebase service account key before the application will work properly."
      fi
    fi
  else
    echo "✅ Firebase service account key found at service_accounts/firebase-${MODE}.json"
  fi

  # GITHUB CONNECTION FOR CI/CD
  echo "===================================================================="
  echo "GITHUB CONNECTION FOR CI/CD"
  echo "===================================================================="

  # Check if GitHub is already connected
  GITHUB_CONNECTED=false
  GITHUB_ALREADY_CONNECTED=${GITHUB_ALREADY_CONNECTED:-false}
  
  # Multiple ways to check if GitHub is connected
  if [[ "$GITHUB_ALREADY_CONNECTED" == "true" ]]; then
    echo "✅ GitHub connection confirmed as already authorized via GITHUB_ALREADY_CONNECTED flag"
    GITHUB_CONNECTED=true
  else
    # Try multiple methods to detect GitHub connection
    GITHUB_CONNECTED_REPOS=$(gcloud beta builds triggers list --project="$PROJECT_NAME" --format="value(github)" 2>/dev/null || echo "")
    
    if [[ -n "$GITHUB_CONNECTED_REPOS" ]]; then
      echo "✅ GitHub connection detected in your GCP project"
      GITHUB_CONNECTED=true
      echo "Add GITHUB_ALREADY_CONNECTED=true to your .env file to skip detection in the future"
    else
      echo "⚠️ GitHub connection not detected. You need to connect GitHub to Cloud Build."
      echo ""
      echo "===== STEP-BY-STEP GITHUB CONNECTION GUIDE ====="
      echo ""
      echo "1. Connect your GitHub account to Cloud Build:"
      echo "   a. Visit: https://console.cloud.google.com/cloud-build/triggers/connect?project=$PROJECT_NAME"
      echo "   b. Choose 'GitHub (Cloud Build GitHub App)' and click 'Continue'"
      echo "   c. Authenticate with your GitHub account if prompted"
      echo ""
      echo "2. Install/Configure Cloud Build App in GitHub:"
      echo "   a. You'll be redirected to GitHub to install the Google Cloud Build app"
      echo "   b. Select either 'All repositories' or choose specific repositories"
      echo "   c. Make sure '$GITHUB_OWNER/$REPO_NAME' is selected"
      echo "   d. Click 'Install' (or 'Configure' if the app is already installed)"
      echo ""
      echo "3. Complete the connection in GCP Console:"
      echo "   a. You'll be redirected back to the GCP Console"
      echo "   b. Select your repository '$REPO_NAME' from the list"
      echo "   c. Click 'Connect' to finalize the connection"
      echo ""
      echo "4. After connecting, DO NOT create a trigger yet!"
      echo "   a. Return to this terminal window"
      echo "   b. Confirm the connection is complete so this script can continue"
      echo ""
      echo "Would you like to open the Cloud Build GitHub connection page now? (y/n)"
      read -r OPEN_GITHUB
      if [[ "$OPEN_GITHUB" == "y" || "$OPEN_GITHUB" == "Y" ]]; then
        # Try to open URL using appropriate command based on OS
        if [[ "$OSTYPE" == "darwin"* ]]; then
          open "https://console.cloud.google.com/cloud-build/triggers/connect?project=$PROJECT_NAME"
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
          xdg-open "https://console.cloud.google.com/cloud-build/triggers/connect?project=$PROJECT_NAME" &>/dev/null
        else
          echo "Please manually visit: https://console.cloud.google.com/cloud-build/triggers/connect?project=$PROJECT_NAME"
        fi
        
        echo ""
        echo "Please confirm when you've completed all the GitHub connection steps (y/n):"
        read -r GITHUB_SETUP_DONE
        if [[ "$GITHUB_SETUP_DONE" == "y" || "$GITHUB_SETUP_DONE" == "Y" ]]; then
          GITHUB_CONNECTED=true
          echo "✅ GitHub connection confirmed"
          echo "Add GITHUB_ALREADY_CONNECTED=true to your .env file to skip this step next time"
        fi
      fi
    fi
  fi

  # If GitHub is connected, create the trigger using gcloud instead of Terraform
  if [[ "$GITHUB_CONNECTED" == "true" ]]; then
    # Skip Terraform for the GitHub-specific resources
    sed -i'.bak' 's/skip_resource_creation = .*/skip_resource_creation = true/' terraform/cicd/terraform.tfvars
    rm -f terraform/cicd/terraform.tfvars.bak 2>/dev/null || true
    
    # Initialize and apply Terraform for CICD (for non-GitHub resources)
    echo "Running Terraform CICD setup for non-GitHub resources..."
    cd terraform/cicd
    terraform init
    terraform apply -auto-approve || {
      echo "⚠️ There were some errors in the CICD setup, but we'll continue."
      echo "These are typically not critical and deployment can still proceed."
    }
    cd ../..
    
    # Check if the trigger already exists
    TRIGGER_EXISTS=$(gcloud builds triggers list --project="$PROJECT_NAME" --filter="name=dev-branch-trigger" --format="value(name)" 2>/dev/null || echo "")
    
    if [[ -z "$TRIGGER_EXISTS" ]]; then
      echo ""
      echo "===== CREATING CLOUD BUILD TRIGGER ====="
      echo "Attempting to create Cloud Build trigger automatically..."
      
      # Create the trigger using gcloud with our custom timeout
      if run_with_timeout "gcloud builds triggers create github --name=\"dev-branch-trigger\" --description=\"Build and deploy on any branch except master\" --repo-owner=\"$GITHUB_OWNER\" --repo-name=\"$REPO_NAME\" --branch-pattern=\"^(?!master$).*$\" --build-config=\"cloudbuild.yaml\" --included-files=\"app/**,docker/**,config,cloudbuild.yaml,pyproject.toml\" --substitutions=\"_SERVICE_NAME=$SERVICE_NAME,_REPO_NAME=$REPO_NAME,_REGION=$REGION,_PROJECT_ENV=$MODE\" --project=\"$PROJECT_NAME\"" 30 "Trigger creation"; then
        echo "✅ Trigger created successfully"
      else
        TRIGGER_ERROR=$?
        echo ""
        echo "⚠️ Automatic trigger creation failed with exit code $TRIGGER_ERROR."
        if [ $TRIGGER_ERROR -eq 1 ]; then
          echo "This might be due to one of these common issues:"
          echo "  - GitHub repository not found or not properly connected"
          echo "  - Invalid branch pattern"
          echo "  - Missing permissions or authentication issues"
        fi
        echo ""
        echo "⚠️ You need to create the trigger manually."
        echo ""
        echo "===== STEP-BY-STEP MANUAL TRIGGER CREATION GUIDE ====="
        echo ""
        echo "1. Open the Cloud Build Triggers page:"
        echo "   https://console.cloud.google.com/cloud-build/triggers/add;region=$REGION?project=$PROJECT_NAME"
        echo ""
        echo "2. Create a new trigger with these settings:"
        echo "   a. Name: dev-branch-trigger"
        echo "   b. Description: Build and deploy on any branch except master"
        echo "   c. Event: Push to a branch"
        echo "   d. Source: First Generation (if prompted)"
        echo "   e. Repository: $GITHUB_OWNER/$REPO_NAME (select from dropdown)"
        echo "   f. Branch: Use '.*' for the branch pattern (to match all branches, then manually exclude master after trigger creation)"
        echo "      NOTE: You'll need to edit the trigger after creation to exclude 'master' branch"
        echo ""
        echo "3. Configuration settings:"
        echo "   a. Type: Cloud Build configuration file (yaml or json)"
        echo "   b. Location: Repository"
        echo "   c. Cloud Build configuration file location: cloudbuild.yaml"
        echo ""
        echo "4. Add the following substitution variables:"
        echo "   _SERVICE_NAME: $SERVICE_NAME"
        echo "   _REPO_NAME: $REPO_NAME"
        echo "   _REGION: $REGION"
        echo "   _PROJECT_ENV: $MODE"
        echo ""
        echo "5. Click 'Create' to save the trigger"
        echo ""
        echo "6. Test the trigger by pushing a change to any branch except master"
        echo ""
        echo "Would you like to open the trigger creation page now? (y/n)"
        read -r OPEN_TRIGGER_PAGE
        if [[ "$OPEN_TRIGGER_PAGE" == "y" || "$OPEN_TRIGGER_PAGE" == "Y" ]]; then
          if [[ "$OSTYPE" == "darwin"* ]]; then
            open "https://console.cloud.google.com/cloud-build/triggers/add;region=$REGION?project=$PROJECT_NAME"
          elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            xdg-open "https://console.cloud.google.com/cloud-build/triggers/add;region=$REGION?project=$PROJECT_NAME" &>/dev/null
          else
            echo "Please manually visit: https://console.cloud.google.com/cloud-build/triggers/add;region=$REGION?project=$PROJECT_NAME"
          fi
        fi
      }
    else
      echo "✅ Cloud Build trigger 'dev-branch-trigger' already exists"
    fi
    
    echo ""
    echo "===== VERIFYING CI/CD SETUP ====="
    echo "✅ CICD setup completed"
    echo ""
    echo "To test your CI/CD pipeline:"
    echo "1. Create a new branch: git checkout -b feature/test-cicd"
    echo "2. Make a small change: echo '# Test CI/CD' >> README.md"
    echo "3. Commit and push: git add README.md && git commit -m 'Test CI/CD' && git push origin feature/test-cicd"
    echo "4. Check build status: https://console.cloud.google.com/cloud-build/builds?project=$PROJECT_NAME"
    echo ""

    # Create environment-specific triggers based on MODE
    if [ "$MODE" = "dev" ]; then
      # Create the development trigger (already done above - all branches except master)
      echo "✅ Development trigger created: Builds on any branch except master"
      
    elif [ "$MODE" = "staging" ]; then
      # Create the staging trigger - only master branch
      echo "Creating staging trigger for master branch..."
      if run_with_timeout "gcloud builds triggers create github --name=\"staging-master-branch-trigger\" --description=\"Build and deploy on push to master branch only\" --repo-owner=\"$GITHUB_OWNER\" --repo-name=\"$REPO_NAME\" --branch-pattern=\"^master$\" --build-config=\"cloudbuild.yaml\" --included-files=\"app/**,docker/**,config,cloudbuild.yaml,pyproject.toml\" --substitutions=\"_SERVICE_NAME=$SERVICE_NAME,_REPO_NAME=$REPO_NAME,_REGION=$REGION,_PROJECT_ENV=$MODE\" --project=\"$PROJECT_NAME\"" 30 "Staging trigger creation"; then
        echo "✅ Staging trigger created successfully"
      else
        echo "⚠️ Staging trigger creation failed, but continuing with setup."
        echo "You'll need to manually create a trigger for the master branch in the Cloud Console."
      fi
        
    elif [ "$MODE" = "prod" ]; then
      # Create the production trigger - only tags starting with 'v'
      echo "Creating production trigger for version tags..."
      if run_with_timeout "gcloud builds triggers create github --name=\"prod-version-tag-trigger\" --description=\"Build and deploy on version tags (v*)\" --repo-owner=\"$GITHUB_OWNER\" --repo-name=\"$REPO_NAME\" --tag-pattern=\"^v.*$\" --build-config=\"cloudbuild.yaml\" --included-files=\"app/**,docker/**,config,cloudbuild.yaml,pyproject.toml\" --substitutions=\"_SERVICE_NAME=$SERVICE_NAME,_REPO_NAME=$REPO_NAME,_REGION=$REGION,_PROJECT_ENV=$MODE\" --project=\"$PROJECT_NAME\"" 30 "Production trigger creation"; then
        echo "✅ Production trigger created successfully"
      else
        echo "⚠️ Production trigger creation failed, but continuing with setup."
        echo "You'll need to manually create a trigger for version tags in the Cloud Console."
      fi
      echo "✅ Production trigger created: Builds only on version tags (v*)"
    fi
  else
    echo ""
    echo "⚠️ GitHub connection is required for CI/CD."
    echo "Please follow the steps above to connect GitHub to Cloud Build and then run this script again."
    echo ""
  fi
fi

echo
echo "===================================================================="
echo "Project $PROJECT_NAME ($MODE environment) setup complete!"
echo "You can now deploy your application with: ./scripts/cicd/deploy.sh"
echo "====================================================================" 