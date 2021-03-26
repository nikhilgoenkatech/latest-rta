#!/bin/bash
# This file contains the functions for installing Prometheus-in-k8s.
# Each function contains a boolean flag so the installations
# can be highly customized.

# ==================================================
#      ----- Components Versions -----             #
# ==================================================
KIAB_RELEASE="release-0.7.3"
ISTIO_VERSION=1.5.1
MICROK8S_CHANNEL="1.18/stable"
PROMETHEUS_K8S="~/k8s"
PROMETHEUS_K8S_REPO="https://github.com/nikhilgoenkatech/k8prometheus.git"

# - The user to run the commands from. Will be overwritten when executing this shell with sudo, this is just needed when spinning machines programatically and running the script with root without an interactive shell
USER="ubuntu"

# Comfortable function for setting the sudo user.
if [ -n "${SUDO_USER}" ]; then
  USER=$SUDO_USER
fi
echo "running sudo commands as $USER"

# Wrapper for runnig commands for the real owner and not as root
alias bashas="sudo -H -u ${USER} bash -c"
# Expand aliases for non-interactive shell
shopt -s expand_aliases

# ======================================================================
#       -------- Function boolean flags ----------                     #
#  Each function flag representas a function and will be evaluated     #
#  before execution.                                                   #
# ======================================================================
# If you add varibles here, dont forget the function definition and the priting in printFlags function.
verbose_mode=false
update_ubuntu=false
docker_install=false
microk8s_install=false
setup_proaliases=false
enable_k8dashboard=false
enable_registry=false
istio_install=false
helm_install=false
certmanager_install=false
certmanager_enable=false
resources_clone=false

git_deploy=false
git_migrate=false

dynatrace_savecredentials=false
dynatrace_configure_monitoring=false
dynatrace_activegate_install=false
dynatrace_configure_workloads=false

jenkins_deploy=false

expose_kubernetes_api=false
expose_kubernetes_dashboard=false
patch_kubernetes_dashboard=false
create_workshop_user=false

# ======================================================================
#             ------- Installation Bundles  --------                   #
#  Each bundle has a set of modules (or functions) that will be        #
#  activated upon installation.                                        #
# ======================================================================
installationBundleDemo() {
  selected_bundle="installationBundleDemo"
  update_ubuntu=true
  docker_install=true
  microk8s_install=true
  setup_proaliases=true

  enable_k8dashboard=true
  istio_install=true
  helm_install=true

  certmanager_install=false
  certmanager_enable=false

  resources_clone=true

  git_deploy=true
  git_migrate=true

  dynatrace_savecredentials=true
  dynatrace_configure_monitoring=true
  dynatrace_activegate_install=true
  dynatrace_configure_workloads=true

  expose_kubernetes_api=true
  expose_kubernetes_dashboard=true
  patch_kubernetes_dashboard=true
  # By default no WorkshopUser will be created
  create_workshop_user=false
}

installationBundleWorkshop() {
  installationBundleDemo
  enable_registry=true
  create_workshop_user=true
  expose_kubernetes_api=true
  expose_kubernetes_dashboard=true
  patch_kubernetes_dashboard=true

  selected_bundle="installationBundleWorkshop"
}

installationBundleAll() {
  # installation default
  installationBundleWorkshop

  enable_registry=true
  # plus all others
  certmanager_install=true
  certmanager_enable=true
  create_workshop_user=true

  jenkins_deploy=true

  selected_bundle="installationBundleAll"
}

installationBundleKeptnOnly() {
  update_ubuntu=true
  docker_install=true
  microk8s_install=true
  enable_k8dashboard=true

  setup_proaliases=true
  istio_install=true
  helm_install=true
  resources_clone=true

  dynatrace_savecredentials=true
  dynatrace_configure_monitoring=true

  expose_kubernetes_api=true
  expose_kubernetes_dashboard=true


  selected_bundle="installationBundleKeptnOnly"
}

installationBundleKeptnQualityGates() {
  installationBundleKeptnOnly
  
  # We dont need istio nor helm
  istio_install=false
  helm_install=false

  # For the QualityGates we need both flags needs to be enabled

  selected_bundle="installationBundleKeptnQualityGates"
}

installationBundlePerformanceAsAService() {
  installationBundleKeptnQualityGates

  # Jenkins needs Helm for the Chart to be installed
  helm_install=true
  jenkins_deploy=true

  selected_bundle="installationBundlePerformanceAsAService"
}

# ======================================================================
#          ------- Util Functions -------                              #
#  A set of util functions for logging, validating and                 #
#  executing commands.                                                 #
# ======================================================================
thickline="======================================================================"
halfline="============"
thinline="______________________________________________________________________"

setBashas() {
  # Wrapper for runnig commands for the real owner and not as root
  alias bashas="sudo -H -u ${USER} bash -c"
  # Expand aliases for non-interactive shell
  shopt -s expand_aliases
}

# FUNCTIONS DECLARATIONS
timestamp() {
  date +"[%Y-%m-%d %H:%M:%S]"
}

printInfo() {
  echo "[Prometheus-in-k8s|INFO] $(timestamp) |>->-> $1 <-<-<|"
}

printInfoSection() {
  echo "[Prometheus-in-k8s|INFO] $(timestamp) |$thickline"
  echo "[Prometheus-in-k8s|INFO] $(timestamp) |$halfline $1 $halfline"
  echo "[Prometheus-in-k8s|INFO] $(timestamp) |$thinline"
}

printError() {
  echo "[Keptn-In-A-Box|ERROR] $(timestamp) |x-x-> $1 <-x-x|"
}

validateSudo() {
  if [[ $EUID -ne 0 ]]; then
    printError "Prometheus-in-k8s must be run with sudo rights. Exiting installation"
    exit 1
  fi
  printInfo "Prometheus-in-k8s installing with sudo rights:ok"
}

waitForAllPods() {
  RETRY=0
  RETRY_MAX=24
  # Get all pods, count and invert the search for not running nor completed. Status is for deleting the last line of the output
  CMD="bashas \"kubectl get pods -A 2>&1 | grep -c -v -E '(Running|Completed|Terminating|STATUS)'\""
  printInfo "Checking and wait for all pods to run."
  while [[ $RETRY -lt $RETRY_MAX ]]; do
    pods_not_ok=$(eval "$CMD")
    if [[ "$pods_not_ok" == '0' ]]; then
      printInfo "All pods are running."
      break
    fi
    RETRY=$(($RETRY + 1))
    printInfo "Retry: ${RETRY}/${RETRY_MAX} - Wait 10s for $pods_not_ok PoDs to finish or be in state Running ..."
    sleep 10
  done

  if [[ $RETRY == $RETRY_MAX ]]; then
    printError "Pods in namespace ${NAMESPACE} are not running. Exiting installation..."
    bashas "kubectl get pods --field-selector=status.phase!=Running -A"
    exit 1
  fi
}

enableVerbose() {
  if [ "$verbose_mode" = true ]; then
    printInfo "Activating verbose mode"
    set -x
  fi
}

# ======================================================================
#          ----- Installation Functions -------                        #
# The functions for installing the different modules and capabilities. #
# Some functions depend on each other, for understanding the order of  #
# execution see the function doInstallation() defined at the bottom    #
# ======================================================================
updateUbuntu() {
  if [ "$update_ubuntu" = true ]; then
    printInfoSection "Updating Ubuntu apt registry"
    apt update
  fi
}

dockerInstall() {
  if [ "$docker_install" = true ]; then
    printInfoSection "Installing Docker and J Query"
    printInfo "Install J Query"
    apt install jq -y
    printInfo "Install Docker"
    apt install docker.io -y
    service docker start
    usermod -a -G docker $USER
  fi
}

setupProAliases() {
  if [ "$setup_proaliases" = true ]; then
    printInfoSection "Adding Bash and Kubectl Pro CLI aliases to .bash_aliases for user ubuntu and root "
    echo "
      # Alias for ease of use of the CLI
      alias las='ls -las' 
      alias hg='history | grep' 
      alias h='history' 
      alias vaml='vi -c \"set syntax:yaml\" -' 
      alias vson='vi -c \"set syntax:json\" -' 
      alias pg='ps -aux | grep' " >/root/.bash_aliases
    homedir=$(eval echo ~$USER)
    cp /root/.bash_aliases $homedir/.bash_aliases
  fi
}

microk8sInstall() {
  if [ "$microk8s_install" = true ]; then
    printInfoSection "Installing Microkubernetes with Kubernetes Version $MICROK8S_CHANNEL"
    snap install microk8s --channel=$MICROK8S_CHANNEL --classic

    printInfo "allowing the execution of priviledge pods "
    bash -c "echo \"--allow-privileged=true\" >> /var/snap/microk8s/current/args/kube-apiserver"

    printInfo "Add user $USER to microk8 usergroup"
    usermod -a -G microk8s $USER

    printInfo "Update IPTABLES, allow traffic for pods (internal and external) "
    iptables -P FORWARD ACCEPT
    ufw allow in on cni0 && sudo ufw allow out on cni0
    ufw default allow routed

    printInfo "Add alias to Kubectl (Bash completion for kubectl is already enabled in microk8s)"
    snap alias microk8s.kubectl kubectl

    printInfo "Add Snap to the system wide environment."
    sed -i 's~/usr/bin:~/usr/bin:/snap/bin:~g' /etc/environment

    printInfo "Create kubectl file for the user"
    homedirectory=$(eval echo ~$USER)
    bashas "mkdir $homedirectory/.kube"
    bashas "microk8s.config > $homedirectory/.kube/config"
    
    printInfo "Enable dns for the services to be able to communicate internally"
    bashas "microk8s enable dns"

    printInfo "Build docker image from the docker file"
    bashas "docker build . -t app"

    printInfo "Save docker image to a tar archive"
    bashas "docker save app > app.tar" 

    printInfo "Import image to MicroK8s"
    bashas "microk8s ctr image import app.tar"
  fi
}

microk8sStart() {
  printInfoSection "Starting Microk8s"
  bashas 'microk8s.start'
}

microk8sEnableBasic() {
  printInfoSection "Enable DNS, Storage, NGINX Ingress"
  bashas 'microk8s.enable dns'
  waitForAllPods
  bashas 'microk8s.enable storage'
  waitForAllPods
  bashas 'microk8s.enable ingress'
  waitForAllPods
}

microk8sEnableDashboard() {
  if [ "$enable_k8dashboard" = true ]; then
    printInfoSection " Enable Kubernetes Dashboard"
    bashas 'microk8s.enable dashboard'
    waitForAllPods
  fi
}

microk8sEnableRegistry() {
  if [ "$enable_registry" = true ]; then
    printInfoSection "Enable own Docker Registry"
    bashas 'microk8s.enable registry'
    waitForAllPods
  fi
}

# We install  Istio manually since Microk8s 1.18 classic comes with 1.3.4 and 1.5.1 is leightweit
istioInstall() {
  if [ "$istio_install" = true ]; then
    printInfoSection "Install istio $ISTIO_VERSION into /opt and add it to user/local/bin"
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
    mv istio-$ISTIO_VERSION /opt/istio-$ISTIO_VERSION
    chmod +x -R /opt/istio-$ISTIO_VERSION/
    ln -s /opt/istio-$ISTIO_VERSION/bin/istioctl /usr/local/bin/istioctl
    bashas "echo 'y' | istioctl manifest apply --force"
    waitForAllPods
  fi
}

helmInstall() {
  if [ "$helm_install" = true ]; then
    printInfoSection "Installing HELM 3 & Client via Microk8s addon"
    bashas 'microk8s.enable helm3'
    printInfo "Adding alias for helm client"
    snap alias microk8s.helm3 helm
    printInfo "Adding Default repo for Helm"
    bashas "helm repo add stable https://charts.helm.sh/stable"
    printInfo "Adding Jenkins repo for Helm"
    bashas "helm repo add jenkins https://charts.jenkins.io"
    printInfo "Adding GiteaCharts for Helm"
    bashas "helm repo add gitea-charts https://dl.gitea.io/charts/"
    printInfo "Updating Helm Repository"
    bashas "helm repo update"
  fi
}

resourcesClone() {
  if [ "$resources_clone" = true ]; then
    printInfoSection "Clone Prometheus-in-k8s Resources in $PROMETHEUS_K8S"
    bashas "git clone $PROMETHEUS_K8S_REPO $PROMETHEUS_K8S"
  fi
}


jenkinsDeploy() {
  if [ "$jenkins_deploy" = true ]; then
    printInfoSection "Deploying Jenkins via Helm. This Jenkins is configured and managed 'as code'"
    bashas "cd $PROMETHEUS_K8S/resources/jenkins && bash deploy-jenkins.sh ${DOMAIN}"
    bashas "cd $PROMETHEUS_K8S/resources/ingress && bash create-ingress.sh ${DOMAIN} jenkins"
  fi
}

gitDeploy() {
  if [ "$git_deploy" = true ]; then
    printInfoSection "Deploying self-hosted GIT(ea) service via Helm."
    bashas "cd $PROMETHEUS_K8S/resources/gitea && bash deploy-gitea.sh ${DOMAIN}"
    bashas "cd $PROMETHEUS_K8S/resources/ingress && bash create-ingress.sh ${DOMAIN} gitea"
  fi
}

gitMigrate() {
  if [ "$git_migrate" = true ]; then
    printInfoSection "Migrating Prometheus-in-k8s projects to a self-hosted GIT(ea) service."
    bashas "cd $PROMETHEUS_K8S/resources/gitea && bash update-git-keptn.sh ${DOMAIN}"
  fi
}

exposeK8Services() {
  if [ "$expose_kubernetes_api" = true ]; then
    printInfoSection "Exposing the Kubernetes Cluster API"
    bashas "cd $PROMETHEUS_K8S/resources/ingress && bash create-ingress.sh ${DOMAIN} k8-api"
  fi
  if [ "$expose_kubernetes_dashboard" = true ]; then
    printInfoSection "Exposing the Kubernetes Dashboard"
    bashas "cd $PROMETHEUS_K8S/resources/ingress && bash create-ingress.sh ${DOMAIN} k8-dashboard"
  fi
  if [ "$istio_install" = true ]; then
    printInfoSection "Exposing Istio Service Mesh as fallBack for nonmapped hosts (subdomains)"
    bashas "cd $PROMETHEUS_K8S/resources/ingress && bash create-ingress.sh ${DOMAIN} istio-ingress"
  fi
}

patchKubernetesDashboard() {
  if [ "$patch_kubernetes_dashboard" = true ]; then
    printInfoSection "Patching Kubernetes Dashboard, use only for learning and Workshops"
    echo "Skip Login in K8 Dashboard"
    bashas "cd $PROMETHEUS_K8S/resources/misc && bash patch-kubernetes-dashboard.sh"
  fi
}

createWorkshopUser() {
  if [ "$create_workshop_user" = true ]; then
    printInfoSection "Creating Workshop User from user($USER) into($NEWUSER)"
    homedirectory=$(eval echo ~$USER)
    printInfo "copy home directories and configurations"
    cp -R $homedirectory /home/$NEWUSER
    printInfo "Create user"
    useradd -s /bin/bash -d /home/$NEWUSER -m -G sudo -p $(openssl passwd -1 $NEWPWD) $NEWUSER
    printInfo "Change diretores rights -r"
    chown -R $NEWUSER:$NEWUSER /home/$NEWUSER
    usermod -a -G docker $NEWUSER
    usermod -a -G microk8s $NEWUSER
    printInfo "Warning: allowing SSH passwordAuthentication into the sshd_config"
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    service sshd restart
  fi
}

printInstalltime() {
  DURATION=$SECONDS
  printInfoSection "Installation complete :)"
  printInfo "It took $(($DURATION / 60)) minutes and $(($DURATION % 60)) seconds"
  printInfoSection "Keptn & Kubernetes Exposed Ingress Endpoints"
  printInfo "Below you'll find the adresses and the credentials to the exposed services."
  printInfo "We wish you a lot of fun in your Autonomous Cloud journey!"
  echo ""
  bashas "kubectl get ing -A"


  if [ "$jenkins_deploy" = true ]; then
    printInfoSection "Jenkins-Server Access"
    printInfo "Username: D1PJenkinsUser"
    printInfo "Password: D1PJenkinsUser"
  fi 

  if [ "$git_deploy" = true ]; then
    printInfoSection "Git-Server Access"
    bashas "bash $PROMETHEUS_K8S/resources/gitea/gitea-vars.sh ${DOMAIN}"
    printInfo "ApiToken to be found on $PROMETHEUS_K8S/resources/gitea/keptn-token.json"
    printInfo "For migrating keptn projects to your self-hosted git repository afterwards just execute the following function:"
    printInfo "cd $PROMETHEUS_K8S/resources/gitea/ && source ./gitea-functions.sh; createKeptnRepoManually {project-name}"
  fi 

  if [ "$create_workshop_user" = true ]; then
    printInfoSection "Workshop User Access (SSH Access)"
    printInfo "ssh ${NEWUSER}@${DOMAIN}"
    printInfo "Password: ${NEWPWD}"
  fi 
  
}


# ======================================================================
#            ---- The Installation function -----                      #
#  The order of the subfunctions are defined in a sequencial order     #
#  since ones depend on another.                                       #
# ======================================================================
doInstallation() {
  echo ""
  printInfoSection "Init Installation at  $(date) by user $(whoami)"
  printInfo "Setting up Microk8s (SingleNode K8s Dev Cluster) with Keptn"
  echo ""
  # Record time of installation
  SECONDS=0

  echo ""
  validateSudo
  setBashas

  enableVerbose
  updateUbuntu
  setupProAliases

  dockerInstall
  microk8sInstall
  microk8sStart
  microk8sEnableDashboard
  microk8sEnableRegistry
  dynatraceActiveGateInstall

  printInstalltime
}

# When the functions are loaded in the Keptn-in-a-box Shell this message will be printed out.
printInfo "Prometheus-in-k8s installation functions loaded in the current shell"
