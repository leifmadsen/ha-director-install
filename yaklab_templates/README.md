# spinup undercloud from host

We make use of a newly installed CentOS 7.5 baremetal node for the purposes of
hosting our undercloud virtual machine. It's assumed that you have your network
setup, VLANs, etc.

[[TODO]] add diagram showing physical setup of the yaklab + VLAN configuration

## Prerequisites

    ssh root@virthost2
    cd ~
    yum install epel-release -y
    yum install python2-pip -y
    systemctl disable firewalld.service
    systemctl stop firewalld.service        # because I'm behind another FW

    git clone https://github.com/redhat-openstack/infrared
    git clone https://github.com/leifmadsen/ha-director-install cloud-configs
    cd ~/cloud-configs/
    git fetch --all && git checkout origin/ir-osp13-yaklab

## Create undercloud

    cd ~/infrared/
    virtualenv .venv
    echo ". $(pwd)/etc/bash_completion.d/infrared" >> .venv/bin/activate
    source .venv/bin/activate
    pip install --upgrade pip && pip install --upgrade setuptools
    pip install .

    infrared activate plugin/virsh

    # copy in our undercloud and network configurations
    cp ~/cloud-configs/yaklab_templates/plugins/virsh/vars/topology/network/bridged_undercloud.yml \
        ./plugins/virsh/vars/topology/network/

    ir virsh --host-address localhost --host-key ~/.ssh/id_rsa \
        --topology-nodes "undercloud:1" --topology-network bridged_undercloud \
        --disk-pool /home/images/infrared \
        --image-url https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2

> **WARNING**
>
> I've had issues with networking coming up properly in the undercloud before
> some commands are executed by Ansible. Not sure what the delay is, but adding
> a delay in the `deploy.yml` file before the undercloud is deployed seems to
> help (I used 60 seconds in a `shell` module).
>
> Additionally, sometimes the upstream tarfile images weren't pulling properly.
> Pre-populating the `/home/stack` directory with the `.tar.` files from the
> `images-url` below is a work around.

    # this may fail simply because it seems to have an issue after the reboot
    # where the network doesn't seem to come up in time, and the `yum update`
    # fails in the undercloud setup/installation

    ir tripleo-undercloud -vv --version queens --images-task=import \
        --images-url=https://images.rdoproject.org/queens/rdo_trunk/current-tripleo/stable/ \
        --disk-pool /home/images/infrared/overcloud --config-file ~/cloud-configs/yaklab_templates/undercloud.conf

## Teardown undercloud

Sometimes this fails as well. I've been finding that `--cleanup true` seems to
work most of the time. If it doesn't work, then try using `--kill true` which I
find fails, but it sets up `--cleanup true` to work, so... .shrug

    ir virsh --host-address localhost --host-key ~/.ssh/id_rsa --topology-network bridged_undercloud --kill true
    ir virsh --host-address localhost --host-key ~/.ssh/id_rsa --topology-network bridged_undercloud --cleanup true

# deploy overcloud

Deployment of the overcloud is done from the undercloud which was created via
infrared. The following setup could probably be automated with infrared at some
point but until everything is solidified we're doing a traditional overcloud
deployment from the CLI.

All commands that follow are assumed to be run from the undercloud after
sourcing the `stackrc` file via `source stackrc`.

Be sure to login as the `stack` user as well, even if you `sudo su - stack`
after login (since I believe you'll need to login as `root` to the undercloud).

## Discover nodes

We'll make use of the autodiscovery mechanism instead of building a static
`instackenv.json` file, because static configurations are for suckers.

    # limit the range to the first part of the network range because I only
    # have 5 nodes, and they are statically assigned IP addresses.
    openstack overcloud node discover --range 192.168.25.0/29 --credentials admin:admin

## Introspect nodes

    openstack overcloud node introspect --all-manageable

## Generate custom roles


    openstack overcloud roles generate --roles-path ~/roles \
        -o ~/tht/roles_data.yaml Controller Compute CustomBaremetal

> **Create custombaremetal flavor**
>
> NOTE: this is totally unnecessary. There is a `baremetal` flavor already
>       setup for the specific purpose of being used by default by custom roles
>
>    openstack flavor create --id auto custombaremetal
>    openstack flavor set \
>        --property "capabilities:boot_option"="local" \
>        --property "capabilities:profile"="custombaremetal" \
>        --property "resources"="CUSTOM_BAREMETAL=1" \
>        custombaremetal

## Tag nodes for roles

_You don't need to do this unless you are trying to set specific nodes to
particular roles._

    openstack baremetal node set --property capabilities='profile:control,boot_option:local' <UUID>
    openstack baremetal node set --property capabilities='profile:compute,boot_option:local' <UUID>
    openstack baremetal node set --property capabilities='profile:baremetal,boot_option:local' <UUID>

## Configure TripleO Heat Templates

### Setup main directories

    cd ~

    # get our local configuration changes, custom roles, etc
    git clone https://github.com/leifmadsen/ha-director-install cloud-configs
    cd ~/cloud-configs
    git fetch --all && git checkout origin/ir-osp13-yaklab


    # create configuration from default templates
    cd ~
    cp -r /usr/share/openstack-tripleo-heat-templates ~/tht/

    mkdir ~/roles/
    cp ~/tht/roles/* ~/roles/
    cp ~/cloud-configs/tht/roles/CustomBaremetal.yaml ~/roles/

### Generate the custom roles data

    openstack overcloud roles generate --roles-path ~/roles/ -o tht/roles_data.yaml Controller CustomBaremetal

### Process templates

    cd ~/tht/

    # create the network ranges and vlans
    cp ~/cloud-configs/yaklab_templates/tht/network_data.yaml ~/tht/

    # modify the environments/network-environment.j2.yaml to point the
    # ControlPlaneDefaultRoute and EC2MetaData to the undercloud IP address

    # process and generate heat templates from jinja templates
    # I also put the processed templates into an alternate directory just to
    # keep things clean
    mkdir ~/tht.built/
    ./tools/process-templates.py -r roles_data.yaml -n network_data.yaml -o ~/tht.built/

## Import containers to local registry

    # build overcloud container file in preparation for download and import
    openstack overcloud container image prepare \
        --namespace docker.io/tripleoqueens \
        --push-destination 192.168.25.252:8787 \
        --output-images-file ~/overcloud_containers.yaml

    # import containers from upstread into local registry
    openstack overcloud container image upload \
        --config-file ~/overcloud_containers.yaml -v

    # create environment file for heat
    openstack overcloud container image prepare \
        --namespace 192.168.25.252:8787/tripleoqueens \
        --env-file ~/docker_registry.yaml

    # allow for an insecure docker registry
    echo "  DockerInsecureRegistryAddress: 192.168.25.252:8787" >> docker_registry.yaml

## Deploy overcloud

    cd ~

    # mark the managed nodes as available for deployment (can also use UUID)
    openstack overcloud node provide --all-manageable

    # deploy the cloud using single nic VLANs
    openstack overcloud deploy --templates ./tht.built/ \
        --roles-file ./tht.built/roles_data.yaml \
        -e ./tht.built/environments/docker.yaml \
        -e ./tht.built/environments/network-isolation.yaml \
        -e ./tht.built/environments/network-environment.yaml \
        -e ~/docker_registry.yaml

# Bring down the overcloud

    openstack stack delete overcloud --yes      # no warning :)
