eval `ssh-agent`    > /dev/null
ssh-add .ssh/id_rsa > /dev/null
env |grep SSH_AUTH_SOCK
env |grep SSH_AGENT_PID
echo export SSH_AUTH_SOCK
echo export SSH_AGENT_PID

