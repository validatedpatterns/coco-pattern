# RHDP support

Red Hat demo platform is a system for employees and red hat partners to generate test infrastructure.
The scripts in this directory help users of that platform automate deployments.

## To deploy

1. Stand up the 'Azure Subscription Based Blank Open Environment'
2. Download the credentials
3. Load the credentials into your environment (e.g. using `direnv`)
4. Launch the wrapper script from the repository root directory:
   1.  `bash ./rhdp/wrapper.sh eastasia`
   2. The wrapper script **requires** an azure region code this code SHOULD be the same as what was selected in RHDP 



