#Create a Certificate Authority
openssl genrsa -out ca.key 4096

openssl req -x509 -new -nodes \
    -key ca.key \
    -sha256 \
    -days 3650 \
    -out ca.crt \
    -subj "/CN=Web3Signer CA"

#Generate the Web3Signer server certificate
openssl genrsa -out server.key 4096

openssl req -new \
    -key server.key \
    -out server.csr \
    -subj "/CN=web3signer"

openssl x509 -req \
    -in server.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out server.crt \
    -days 365 \
    -sha256

#Convert to PKCS12
echo $(openssl rand -base64 32) > server.password

openssl pkcs12 -export \
    -inkey server.key \
    -in server.crt \
    -certfile ca.crt \
    -out server.p12 \
    -passout file:server.password

#Generate the Catalyst client certificate
openssl genrsa -out client.key 4096

openssl req -new \
    -key client.key \
    -out client.csr \
    -subj "/CN=catalyst"

openssl x509 -req \
    -in client.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out client.crt \
    -days 365 \
    -sha256

#Create knownClients
cp client.crt knownClients