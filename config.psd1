@{
    Profile          = 'codex-admin'
    Region           = 'us-east-1'
    AvailabilityZone = 'us-east-1a'
    InstanceName     = 'ubuntu-server-1'
    ProjectTag       = 'codex-ubuntu'
    OwnerTag         = 'Otmane'
    InstanceType     = 'c7i-flex.xlarge'
    ExpectedVcpus    = 4
    ExpectedMemoryMiB = 8192
    RootVolumeGiB    = 80
    KeyPairName      = 'adam-ubuntu-1-20260728'
    SecurityGroupName = 'codex-ubuntu-ssh-20260728'
    PublicTcpPorts   = @(80, 443)
    SshAlias         = 'server'
    SshUser          = 'ubuntu'
    PrivateKeyPath   = 'C:\Users\adam\.ssh\aws-ubuntu-server-1'
    UbuntuAmiParameter = '/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id'
}
