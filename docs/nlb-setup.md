# Running TLS, mTLS, and QUIC Behind an AWS Network Load Balancer

This guide explains how to place an AWS Network Load Balancer (NLB) in TCP passthrough mode between vm1 and vm2 for TLS, mTLS, and QUIC. It covers why public IPs don't work for binding inside EC2, how TCP passthrough works, the AWS setup steps, and the one PKI change you need to make.

## Why Public IPs Don't Work for Binding

When AWS gives an EC2 instance a public IP, that IP is not actually assigned to any network interface inside the VM. There is no `eth0:1` or secondary address — the public IP lives in AWS's NAT layer, outside the VM entirely.

If you run `ip addr` inside the VM, you will only see the private IP (e.g. `10.0.1.x`). Because the IP doesn't exist on any interface, any process that tries to `bind()` to it — including the OpenSSL server — gets an error. That's why the testbed only works with private IPs today.

You cannot fix this by changing the testbed code. It is an AWS networking constraint.

## How NLB TCP Passthrough Solves This

An NLB can accept connections on a public address and forward the raw TCP bytes to a backend VM. Crucially, it does **not** terminate TLS — the full handshake happens between vm1 (client) and vm2 (server), byte for byte. The NLB is invisible to the protocol.

This means:

- vm2's server still binds to its **private IP** (or `0.0.0.0`) — no change needed there
- vm1's client connects to the **NLB's DNS name** instead of vm2's IP
- The NLB forwards the connection to vm2's private IP on the same port

The only thing that changes in the testbed is where vm1 points and what name is in the TLS certificate.

## Architecture

```
vm1 (client)
  |
  | connects to NLB DNS on ports 4433-4436, 4438-4439
  v
AWS NLB  (TCP/UDP passthrough, no TLS termination)
  |
  | forwards raw TCP/UDP to vm2 private IP, same port
  v
vm2 (server)  -- binds to 0.0.0.0 or private IP
```

The NLB is internet-facing (has a public DNS name) but vm2 never needs to know about public IPs.

## Step 1: Create the NLB in AWS

1. Open the EC2 console, go to **Load Balancers**, click **Create load balancer**.
2. Choose **Network Load Balancer**.
3. Settings:
   - Scheme: **Internet-facing** (so vm1 can reach it via public DNS)
   - IP address type: IPv4
   - VPC: same VPC as both EC2 instances
   - Subnets: select the subnet where vm2 lives (and vm1 if they are in different AZs, add both)
4. Click through to **Listeners and routing** — you will add listeners in the next step.
5. Finish creating the NLB. Note the **DNS name** it gets (e.g. `my-nlb-abc123.elb.us-east-1.amazonaws.com`). You will need this later.

## Step 2: Create a Target Group for vm2

1. Go to **Target Groups**, click **Create target group**.
2. Settings:
   - Target type: **Instances**
   - Protocol: **TCP**
   - Port: `4433` (you will reuse or clone this for other ports)
   - VPC: same as above
3. Health check: TCP, port traffic port.
4. Register vm2 as a target. Select the instance directly.
5. Create the target group.

Create one target group per port, or one target group and point multiple listeners at it using port override. Either works.

## Step 3: Add TCP Listeners on the NLB

For each testbed port, add a listener:

| Port | Protocol | Notes                           |
| ---- | -------- | ------------------------------- |
| 4433 | TCP      | TLS classical                   |
| 4434 | TCP      | TLS PQC                         |
| 4435 | TCP      | mTLS classical                  |
| 4436 | TCP      | mTLS PQC                        |
| 4438 | UDP      | QUIC classical (see note below) |
| 4439 | UDP      | QUIC PQC (see note below)       |

**Note on QUIC (UDP):** NLB UDP listeners forward packets to the target, but the source IP seen by vm2 will be the NLB's IP, not vm1's IP. QUIC tracks the client address, so this may or may not work depending on how strictly the implementation checks source addresses. Test QUIC after getting TLS and mTLS working, and fall back to direct VM-to-VM if it fails.

## Step 4: Update vm2's Security Group

Because you used **Instances** as the target type in Step 2, NLB preserves the original client IP (vm1's IP) when forwarding. vm2's security group does not need to change.

## Step 5: Fix the TLS Certificate SAN

The TLS certificate for vm2 currently has vm2's private IP in its Subject Alternative Name (SAN). When vm1 connects to the NLB DNS name, OpenSSL checks whether that name matches the cert's SAN. It won't match, and the handshake fails with a certificate verification error.

You need to regenerate the PKI with the NLB DNS name added to the cert SAN.

You do not edit `pki/ca.cnf` by hand. When `NLB_HOST` is set in `env.sh` (next step), `pki/gen.sh` automatically adds the NLB DNS name as a second DNS SAN (`DNS.2`) alongside vm2's private IP and hostname. The certificate then validates whether the client connects directly to vm2 or through the NLB.

Set `NLB_HOST` first (Step 6), then regenerate the PKI on vm1:

```bash
source env.sh
./pki/gen.sh --proto tls
./pki/gen.sh --proto mtls
./pki/gen.sh --proto quic
```

Sync the new certs to vm2 (use the vars for any one of the three protocols — they all point to the same vm2):

```bash
rsync -a pki/out/ "$TLS_VM2_USER@$TLS_VM2_HOST:$TLS_VM2_REPO/pki/out/"
```

## Step 6: Set NLB_HOST in env.sh on vm1

`env.sh` has an `NLB_HOST` variable. Leave it empty for direct VM-to-VM testing. Set it to the NLB DNS name to route TLS, mTLS, and QUIC through the load balancer:

```bash
export NLB_HOST=my-nlb-abc123.elb.us-east-1.amazonaws.com
```

That is the only change you make. `VM2_IP` and `VM2_HOST` stay pointed at vm2's real private IP and hostname:

- `VM2_IP` and `VM2_HOST` are still used to SSH into vm2 and start the servers.
- `NLB_HOST` becomes the connect target for the client (`s_client -connect`, QUIC, and the reachability probe).
- `pki/gen.sh` reads `NLB_HOST` and adds it to the server cert SAN automatically.

After setting `NLB_HOST`, regenerate the PKI (Step 5) so the cert SAN includes the NLB DNS name.

## Step 7: Test

From vm1:

```bash
source env.sh

# Verify NLB forwards TCP to vm2
timeout 3 bash -c "</dev/tcp/${NLB_HOST}/4433" && echo OPEN || echo BLOCKED

# TLS
./run.sh --proto tls --mode classical
./run.sh --proto tls --mode pqc

# mTLS
./run.sh --proto mtls --mode classical
./run.sh --proto mtls --mode pqc

# QUIC
./run.sh --proto quic --mode classical
./run.sh --proto quic --mode pqc
```

If the cert SAN matches and the NLB listener is active, you should see `Verify: 0` in the output. QUIC may show handshake failures if source IP tracking causes issues — that is expected with UDP through NLB.

## Summary

| What changes                                            | What stays the same                                        |
| ------------------------------------------------------- | ---------------------------------------------------------- |
| `NLB_HOST` set in `env.sh` to the NLB DNS name          | vm2 binds to its private IP                                |
| `pki/gen.sh` adds NLB DNS to the cert SAN automatically | All `server.sh` files                                      |
| PKI regenerated and synced to vm2                       | `VM2_IP` and `VM2_HOST` (still vm2's real address for SSH) |
| NLB created with listeners for each port                | All protocol ports                                         |

NLB TCP passthrough is transparent to TLS. The client connect target switches to `NLB_HOST`; the server side is unchanged.
