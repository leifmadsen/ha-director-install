#!/bin/sh
export SWIFT_PASSWORD=`sudo crudini --get /etc/ironic-inspector/inspector.conf swift password`
if [ ! -d swift-data ]; then
  mkdir swift-data;
fi

for node in $(ironic node-list | grep -v UUID| awk '{print $2}'); 
    do 
      swift -U service:ironic -K $SWIFT_PASSWORD download ironic-inspector inspector_data-$node; 
      if [ -e inspector_data-$node ]; then
        mv inspector_data-$node swift-data;
      fi
  done