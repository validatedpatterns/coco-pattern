#!/bin/bash
mkdir -p ~/.coco-pattern
openssl genpkey -algorithm ed25519 > ~/.coco-pattern/kbsPrivateKey
openssl pkey -in ~/.coco-pattern/kbsPrivateKey -pubout -out ~/.coco-pattern/kbsPublicKey