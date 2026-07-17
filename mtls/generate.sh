create_cnf_file() {
    local name="$1"

    cat > "${name}.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = ${name}

[req_ext]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${name}
EOF
}

#Create a Certificate Authority
openssl genrsa -out ca.key 4096

openssl req -x509 -new -nodes \
    -key ca.key \
    -sha256 \
    -days 3650 \
    -out ca.crt \
    -subj "/CN=Web3Signer CA"

#Generate the Web3Signer L1 server certificate
openssl genrsa -out web3signer_l1.key 4096

create_cnf_file "web3signer_l1"

openssl req \
  -new \
  -key web3signer_l1.key \
  -out web3signer_l1.csr \
  -config web3signer_l1.cnf

openssl x509 \
  -req \
  -in web3signer_l1.csr \
  -CA ca.crt \
  -CAkey ca.key \
  -CAcreateserial \
  -out web3signer_l1.crt \
  -days 365 \
  -sha256 \
  -extensions req_ext \
  -extfile web3signer_l1.cnf

#Convert to PKCS12
# TODO improve password generation, currently it is just a random string
echo $(openssl rand -base64 32) > web3signer_l1.password

openssl pkcs12 \
  -export \
  -inkey web3signer_l1.key \
  -in web3signer_l1.crt \
  -certfile ca.crt \
  -out web3signer_l1.p12 \
  -passout file:web3signer_l1.password

#Generate the Web3Signer L2 server certificate
openssl genrsa -out web3signer_l2.key 4096

create_cnf_file "web3signer_l2"

openssl req \
  -new \
  -key web3signer_l2.key \
  -out web3signer_l2.csr \
  -config web3signer_l2.cnf

openssl x509 \
  -req \
  -in web3signer_l2.csr \
  -CA ca.crt \
  -CAkey ca.key \
  -CAcreateserial \
  -out web3signer_l2.crt \
  -days 365 \
  -sha256 \
  -extensions req_ext \
  -extfile web3signer_l2.cnf

#Convert to PKCS12
echo $(openssl rand -base64 32) > web3signer_l2.password

openssl pkcs12 \
  -export \
  -inkey web3signer_l2.key \
  -in web3signer_l2.crt \
  -certfile ca.crt \
  -out web3signer_l2.p12 \
  -passout file:web3signer_l2.password


#Generate the Catalyst client certificate
openssl genrsa -out catalyst.key 4096

cat > "catalyst.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = catalyst

[req_ext]
extendedKeyUsage = clientAuth
EOF

openssl req \
  -new \
  -key catalyst.key \
  -out catalyst.csr \
  -config catalyst.cnf

openssl x509 \
  -req \
  -in catalyst.csr \
  -CA ca.crt \
  -CAkey ca.key \
  -CAcreateserial \
  -out catalyst.crt \
  -days 365 \
  -sha256 \
  -extensions req_ext \
  -extfile catalyst.cnf

#Create knownClients
cp catalyst.crt knownClients