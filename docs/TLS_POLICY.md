# TLS 1.2 + Modern Cipher Policy

You asked for TLS 1.2 and latest ciphers. This document is precise about **where
TLS is a knob you set** versus where it is AWS-managed, so the production posture
is unambiguous.

## 1. AWS control-plane / data-plane APIs — managed, TLS 1.2+ already

Calls to EventBridge, SNS, SQS, Lambda, KMS, S3, CloudWatch are **HTTPS-only**
and negotiated by AWS at **TLS 1.2 or higher with modern cipher suites**. There
is no cleartext option and no cipher list for you to set — AWS retired TLS 1.0/1.1
across services. You cannot "downgrade" these, so the only hardening available is
to **refuse non-TLS requests outright**, which this lab does:

| Resource | Enforcement (in code) |
| --- | --- |
| S3 state bucket | bucket policy `Deny` when `aws:SecureTransport = false` (+ optional `s3:TlsVersion` ≥ 1.2 in prod) |
| SQS DLQ | queue policy `Deny sqs:*` when `aws:SecureTransport = false` |
| Application SNS topic | topic policy `Deny sns:Publish` when `aws:SecureTransport = false` |
| Alerts SNS topic | topic policy `Deny` when `aws:SecureTransport = false` |

## 2. EventBridge API Destinations (outbound HTTPS) — TLS 1.2 to YOUR endpoint

When EventBridge delivers to an **API destination** (an external/HTTP target),
it opens an outbound HTTPS connection and negotiates **TLS 1.2**. The cipher
suite and minimum protocol are decided by **your endpoint's TLS termination**,
not by EventBridge. So the cipher policy lives on whatever fronts your endpoint:

### If fronted by an Application Load Balancer

```hcl
resource "aws_lb_listener" "https" {
  # ...
  protocol    = "HTTPS"
  ssl_policy  = "ELBSecurityPolicy-TLS13-1-2-2021-06"  # TLS 1.2+1.3, modern ciphers only
  certificate_arn = aws_acm_certificate.cert.arn
}
```

### If fronted by CloudFront

```hcl
resource "aws_cloudfront_distribution" "this" {
  # ...
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cert.arn
    minimum_protocol_version = "TLSv1.2_2021"   # TLS 1.2 floor, modern ciphers
    ssl_support_method       = "sni-only"
  }
}
```

### If fronted by API Gateway

```hcl
resource "aws_api_gateway_domain_name" "this" {
  security_policy = "TLS_1_2"
  # ...
}
```

Recommended security policies (TLS 1.2 floor, no weak ciphers):

| Service | Policy |
| --- | --- |
| ALB / NLB | `ELBSecurityPolicy-TLS13-1-2-2021-06` |
| CloudFront | `TLSv1.2_2021` |
| API Gateway | `TLS_1_2` |

These policies exclude 3DES/RC4/CBC-legacy suites and negotiate ECDHE + AES-GCM
/ ChaCha20-Poly1305.

## 3. EventBridge Connections (API destination auth)

An `aws_cloudwatch_event_connection` holds the credential EventBridge uses to
call your API destination. Store secrets in the connection (backed by Secrets
Manager) — never in plaintext — and the connection itself is reached over TLS.

## 4. This lab

The sandbox test uses **Lambda, SNS, and CloudWatch Logs** targets — all
in-account AWS services over managed TLS 1.2+, with the non-TLS-deny policies
above applied. **No public HTTP endpoint or API destination is created in the
sandbox**, because that requires a domain + ACM certificate you own. When you add
one for production, front it with one of the security policies in section 2 and
the TLS 1.2 + modern-cipher requirement is satisfied end to end.
