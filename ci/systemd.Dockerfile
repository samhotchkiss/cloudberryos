# Service-level test image for CloudberryOS (docs/packaging-goal.md "Test
# environment", the optional systemd-in-Docker alternative to the Lima VM).
# Stock ubuntu:26.04 has no /sbin/init or systemd; this derives an image that
# does, so ci/services-stage.sh can drive `systemctl`, `nft`, and squid the
# same way a real machine would.
# Package list matches the doc's Dockerfile exactly, plus two test-only
# additions (never shipped in the .deb, never a Depends): `curl` (the
# Block B acceptance text itself curls the child homepage) and `iptables`
# (needed only so tests/fixtures/prototype-install.sh's prototype firewall
# unit -- deliberately still iptables-only, reproducing prototype defect
# #1 -- can actually start under the prototype-migration test).
FROM ubuntu:26.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd systemd-sysv dbus adduser sudo python3 squid nftables libglib2.0-bin xdg-utils \
    curl iptables \
    && apt-get clean
# Ubuntu's Docker base image ships /usr/sbin/policy-rc.d (returns 101) to stop
# daemons auto-starting in an image with no init. This image DOES boot systemd
# as PID 1, and leaving policy-rc.d in place makes deb-systemd-invoke a no-op --
# which would silently skip the firewall unit's ExecStop on package remove, the
# very systemd integration Block B is here to test. A real booted machine has no
# such file; remove it so this container behaves like one.
RUN rm -f /usr/sbin/policy-rc.d
CMD ["/sbin/init"]
