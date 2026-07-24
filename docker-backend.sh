#!/bin/bash 
export DOCKER_IMAGE=intel/llm-scaler-vllm:0.21.0-b1 
export CONTAINER_NAME=llm-serving 
docker rm -f $CONTAINER_NAME 
sudo docker run -td \
       	--privileged \
       	--net=host \
       	--device=/dev/dri \
       	--name=$CONTAINER_NAME \
       	-v /home/b70/LLM:/llm/models/ \
       	-v /home/b70/llm-server:/llm/ \
       	-e no_proxy=localhost,127.0.0.1 \
       	--shm-size="32g" \
       	--entrypoint /bin/bash \
        $DOCKER_IMAGE
