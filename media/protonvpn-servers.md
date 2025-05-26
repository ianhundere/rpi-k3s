# ProtonVPN Server Reference

This document contains a list of valid ProtonVPN server hostnames for use with Gluetun VPN container as of May 2025.

## Verifying Current Valid Hostnames

To get the current list of valid hostnames, run this command on a pod with Gluetun that has an invalid hostname configured:

```bash
kubectl logs -n media YOUR_POD_NAME -c gluetun
```

The error message will show all valid hostnames currently supported.

## Valid ProtonVPN Server Hostnames (for use with SERVER_HOSTNAMES parameter)

The following servers were identified as valid options for the `SERVER_HOSTNAMES` parameter in Gluetun:

### Africa & Middle East

- al-01.protonvpn.net, al-02.protonvpn.net
- ao-02.protonvpn.net
- dz-01.protonvpn.net, dz-02.protonvpn.net
- eg-01.protonvpn.net, eg-02.protonvpn.net
- jo-02.protonvpn.net
- ke-02.protonvpn.net
- km-02.protonvpn.net
- ma-01.protonvpn.net
- mr-01.protonvpn.net, mr-02.protonvpn.net
- mu-02.protonvpn.net
- mz-01.protonvpn.net, mz-02.protonvpn.net
- qa-01.protonvpn.net, qa-02.protonvpn.net
- rw-01.protonvpn.net, rw-02.protonvpn.net
- sn-01.protonvpn.net, sn-02.protonvpn.net
- so-02.protonvpn.net
- ss-01.protonvpn.net, ss-02.protonvpn.net
- td-01.protonvpn.net, td-02.protonvpn.net
- tg-01.protonvpn.net, tg-02.protonvpn.net
- tn-02.protonvpn.net
- za-01.protonvpn.net, za-02.protonvpn.net

### Asia Pacific

- az-01.protonvpn.net, az-02.protonvpn.net
- bd-01.protonvpn.net
- by-01.protonvpn.net, by-02.protonvpn.net
- hk-04.protonvpn.net through hk-27.protonvpn.net
- id-01.protonvpn.net
- in-05.protonvpn.net, in-06.protonvpn.net
- jp-12.protonvpn.net through jp-30.protonvpn.net
- kh-01.protonvpn.net
- kr-03.protonvpn.net
- lk-01.protonvpn.net
- mm-01.protonvpn.net
- my-01.protonvpn.net, my-09.protonvpn.net
- np-01.protonvpn.net
- ph-01.protonvpn.net
- pk-01.protonvpn.net
- sg-14.protonvpn.net through sg-16.protonvpn.net
- th-01.protonvpn.net
- tw-03.protonvpn.net, tw-04.protonvpn.net
- uz-02.protonvpn.net
- vn-01.protonvpn.net

### Europe

- at-05.protonvpn.net through at-07.protonvpn.net
- be-02.protonvpn.net, be-04.protonvpn.net, be-05.protonvpn.net
- bg-02.protonvpn.net
- ch-02.protonvpn.net through ch-23.protonvpn.net
- cy-01.protonvpn.net
- cz-04.protonvpn.net, cz-05.protonvpn.net
- de-12.protonvpn.net through de-25.protonvpn.net
- dk-03.protonvpn.net, dk-05.protonvpn.net, dk-06.protonvpn.net
- ee-01.protonvpn.net, ee-02.protonvpn.net
- es-03.protonvpn.net through es-09.protonvpn.net
- fi-01.protonvpn.net, fi-02.protonvpn.net, fi-03.protonvpn.net
- fr-07.protonvpn.net, fr-13.protonvpn.net through fr-24.protonvpn.net
- ge-03.protonvpn.net
- gr-01.protonvpn.net
- hr-01.protonvpn.net, hr-02.protonvpn.net
- hu-03.protonvpn.net, hu-04.protonvpn.net
- ie-01.protonvpn.net, ie-03.protonvpn.net
- is-01.protonvpn.net, is-02.protonvpn.net
- it-04.protonvpn.net through it-07.protonvpn.net
- lt-01b.protonvpn.net
- lu-02b.protonvpn.net, lu-03.protonvpn.net, lu-04.protonvpn.net
- lv-01.protonvpn.net, lv-02.protonvpn.net
- md-02.protonvpn.net
- me-02.protonvpn.net
- mk-01.protonvpn.net
- mt-01.protonvpn.net
- nl-01.protonvpn.net, nl-05.protonvpn.net, nl-13.protonvpn.net, nl-28.protonvpn.net through nl-30.protonvpn.net, nl-47.protonvpn.net, nl-53.protonvpn.net, nl-74.protonvpn.net, nl-108.protonvpn.net, nl-149.protonvpn.net, nl-150.protonvpn.net, nl-165.protonvpn.net through nl-168.protonvpn.net, nl-204.protonvpn.net through nl-209.protonvpn.net, nl-211.protonvpn.net
- no-03.protonvpn.net, no-05.protonvpn.net, no-06.protonvpn.net
- pl-05.protonvpn.net through pl-07.protonvpn.net
- pt-02b.protonvpn.net, pt-03.protonvpn.net
- ro-02.protonvpn.net, ro-08.protonvpn.net
- rs-01.protonvpn.net, rs-02.protonvpn.net
- ru-04.protonvpn.net, ru-05.protonvpn.net
- se-01.protonvpn.net, se-02.protonvpn.net, se-05.protonvpn.net through se-09.protonvpn.net
- si-01.protonvpn.net
- sk-01.protonvpn.net, sk-02.protonvpn.net
- tr-03.protonvpn.net, tr-25.protonvpn.net
- ua-02.protonvpn.net, ua-03.protonvpn.net
- uk-09.protonvpn.net, uk-10.protonvpn.net, uk-12.protonvpn.net through uk-25.protonvpn.net

### Americas

- ar-03.protonvpn.net, ar-04.protonvpn.net
- br-03.protonvpn.net, br-04.protonvpn.net
- ca-09.protonvpn.net, ca-12.protonvpn.net, ca-13.protonvpn.net, ca-16.protonvpn.net through ca-36.protonvpn.net
- cl-04.protonvpn.net
- co-02.protonvpn.net, co-03.protonvpn.net
- cr-02.protonvpn.net
- ec-01.protonvpn.net
- mx-03.protonvpn.net, mx-04.protonvpn.net
- pe-04.protonvpn.net
- pr-01.protonvpn.net
- sv-01.protonvpn.net
- us-31.protonvpn.net, us-56.protonvpn.net through us-59.protonvpn.net, us-61.protonvpn.net, us-66.protonvpn.net, us-67.protonvpn.net, us-69.protonvpn.net, us-74.protonvpn.net, us-75.protonvpn.net, us-93.protonvpn.net, us-94.protonvpn.net, us-108.protonvpn.net, us-109.protonvpn.net, us-118.protonvpn.net through us-130.protonvpn.net, us-134.protonvpn.net, us-135.protonvpn.net, us-144.protonvpn.net, us-158.protonvpn.net, us-160.protonvpn.net, us-164.protonvpn.net through us-169.protonvpn.net, us-171.protonvpn.net through us-174.protonvpn.net, us-176.protonvpn.net through us-179.protonvpn.net, us-181.protonvpn.net through us-183.protonvpn.net, us-185.protonvpn.net, us-187.protonvpn.net through us-190.protonvpn.net, us-192.protonvpn.net, us-194.protonvpn.net, us-195.protonvpn.net, us-197.protonvpn.net, us-199.protonvpn.net through us-264.protonvpn.net
- ve-01.protonvpn.net

## Configuration Notes

### Secure Core Configurations

- **Don't use**: `is-ec-01.protonvpn.com` format
- **Use instead**: `SERVER_HOSTNAMES=node-is-01.protonvpn.net` (standard server from list above)
- **Example**: `node-is-01.protonvpn.net` for Iceland endpoint

### Standard Server Configurations

- **Best option**: `SERVER_COUNTRIES=Switzerland` (for specific country selection)
- **Alternative**: `WIREGUARD_ENDPOINT_IP=138.199.6.178` (direct IP connection)
- **Example**: `SERVER_COUNTRIES=Finland` for Finnish server
