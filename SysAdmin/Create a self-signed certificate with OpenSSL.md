# Create a self-signed certificate with OpenSSL

## Prequisites
You'll need a Linux terminal or Cygwin if you're operating on Windows.

## Steps
1. Create a configuration file.  Fill in the relevant information under ``req_distinguished_name`` for your needs.
```
[ req ]
default_bits            = 2048
encrypt_key             = no
default_md              = sha256
utf8                    = yes
string_mask             = utf8only
prompt                  = no
distinguished_name = req_distinguished_name
x509_extensions = req_ext
[ req_distinguished_name ]
countryName         = US
stateOrProvinceName = Ohio
localityName        = Columbus
organizationName    = JoeIT
organizationalUnitName = IT
commonName          = server1.example.com
[ req_ext ]
subjectAltName = @alt_names
[alt_names]
DNS.1 = server1.example.com
DNS.2 = server2.example.com
```

2. Execute the following command.  Adjust the ``-keyout``, ``-out``, ``-days``, and ``-config`` parameters as needed.
``openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -keyout joeit-server.key -out joeit-server.crt -config joeit-server.cnf``