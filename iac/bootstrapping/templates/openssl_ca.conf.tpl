[ req ]
default_bits       = 4096
default_md         = sha256
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[ req_distinguished_name ]
CN = %%COMMON_NAME%%
O  = Nexus

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE
keyUsage               = critical, keyCertSign, cRLSign
