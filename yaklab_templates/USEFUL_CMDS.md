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

    # this may fail simply because it seems to have an issue after the reboot
    # where the network doesn't seem to come up in time, and the `yum update`
    # fails in the undercloud setup/installation

    ir tripleo-undercloud -vv --version queens --images-task=import \
        --images-url=https://images.rdoproject.org/queens/rdo_trunk/current-tripleo/stable/ \
        --disk-pool /home/images/infrared/overcloud --config-file ~/configs/yaklab_templates/undercloud.conf

## Teardown undercloud

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

## Tag nodes for roles

    openstack baremetal node set --property capabilities='node:controller-0,boot_option:local' <UUID>
    openstack baremetal node set --property capabilities='node:compute-0,boot_option:local' <UUID>


## Configure TripleO Heat Templates

    cd ~
    git clone https://github.com/leifmadsen/ha-director-install cloud-configs
    cd ~/cloud-configs
    git fetch --all && git checkout origin/ir-osp13-yaklab
    cd ~

    cp -r /usr/share/openstack-tripleo-heat-templates ~/tht/
    cd ~/tht/
    cp ~/cloud-configs/yaklab_templates/tht/network_data.yaml ~/tht/
    sed -i -e 's/nic1/nic2/g' network/config/single-nic-vlans/role.role.j2.yaml
    ./tools/process-templates.py

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
        --env-file ~/docker_registry_heat.yaml

## Deploy overcloud

    cd ~
    openstack overcloud deploy --templates ./tht/ -e ~/docker_registry.yaml