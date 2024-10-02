#!/bin/bash
# assumes you have ~/values-secret-coco-pattern.yaml
mkdir -p ~/.coco-pattern

ssh-keygen -f ~/.coco-pattern/id_rsa -N ""
