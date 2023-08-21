
{ nixosTest, nixosModule, pkgs, lib }:
let
  wg-snakeoil-keys = import ./snakeoil-keys.nix;
  peer = (import ./make-peer.nix) { inherit lib; };
in
  nixosTest {
    name = "vxlan-nix";
    nodes = {
      peer0 = peer {
        ip4 = "192.168.0.1";
        ip6 = "fd00::1";
        extraConfig = {
          networking.firewall.allowedUDPPorts = [ 8472 23542 ];
          networking.wireguard.interfaces.wg0 = {
            ips = [ "10.23.42.1/32" "fc00::1/128" ];
            listenPort = 23542;

            inherit (wg-snakeoil-keys.peer0) privateKey;

            peers = lib.singleton {
              allowedIPs = [ "10.23.42.2/32" "fc00::2/128" ];

              inherit (wg-snakeoil-keys.peer1) publicKey;
            };
          };
          systemd.services.peer0-vxlan-orchestration = {
            path = [ pkgs.bridge-utils pkgs.git pkgs.iproute2 pkgs.nettools pkgs.nix ];
            enable = true;
            script = with pkgs; ''
              #!/usr/bin/env nix-shell
              #!nix-shell -i bash
              ${iproute2}/bin/ip link add vxlan100 type vxlan id 100 local 10.23.42.1 remote 10.23.42.2
              ${iproute2}/bin/ip link set vxlan100 up
              ${bridge-utils}/bin/brctl addbr br100
              ${bridge-utils}/bin/brctl addif br100 vxlan100
              ${bridge-utils}/bin/brctl stp br100 off
              ${iproute2}/bin/ip link set br100 up
              ${iproute2}/bin/ip addr add 192.168.3.1/24 dev br100

              echo "" > /peer0
            '';

            serviceConfig = {
              Type = "oneshot";
              User = "root";
            };
            after = ["wireguard-wg0.target"];
            wantedBy = [ "multi-user.target" ];
          };
        };
      };

      peer1 = peer {
        ip4 = "192.168.0.2";
        ip6 = "fd00::2";
        extraConfig = {
          networking.firewall.allowedUDPPorts = [ 8472 23542 ];
          networking.wireguard.interfaces.wg0 = {
            ips = [ "10.23.42.2/32" "fc00::2/128" ];
            listenPort = 23542;
            allowedIPsAsRoutes = false;

            inherit (wg-snakeoil-keys.peer1) privateKey;

            peers = lib.singleton {
              allowedIPs = [ "0.0.0.0/0" "::/0" ];
              endpoint = "192.168.0.1:23542";
              persistentKeepalive = 25;

              inherit (wg-snakeoil-keys.peer0) publicKey;
            };

            postSetup = let inherit (pkgs) iproute2; in ''
              ${iproute2}/bin/ip route replace 10.23.42.1/32 dev wg0
              ${iproute2}/bin/ip route replace fc00::1/128 dev wg0
            '';
          };
          systemd.services.peer1-vxlan-orchestration = {
            path = [ pkgs.bridge-utils pkgs.git pkgs.iproute2 pkgs.nettools pkgs.nix ];
            enable = true;
            script = with pkgs; ''
              #!/usr/bin/env nix-shell
              #!nix-shell -i bash

              ${iproute}/bin/ip link add vxlan100 type vxlan id 100 local 10.23.42.2 remote 10.23.42.1
              ${iproute}/bin/ip link set vxlan100 up
              ${bridge-utils}/bin/brctl addbr br100
              ${bridge-utils}/bin/brctl addif br100 vxlan100
              ${bridge-utils}/bin/brctl stp br100 off
              ${iproute}/bin/ip link set br100 up
              ${iproute}/bin/ip addr add 192.168.3.2/24 dev br100

              echo "" > /peer1
            '';
            serviceConfig = {
              Type = "oneshot";
              User = "root";
            };
            after = ["wireguard-wg0.service"];
            wantedBy = [ "multi-user.target" ];
          };
        };
      };
    };

    testScript = ''
      start_all()

      peer0.wait_for_unit("wireguard-wg0.service")
      peer1.wait_for_unit("wireguard-wg0.service")
      peer0.succeed("ls /peer0")
      peer1.succeed("ls /peer1")
 
      peer1.succeed("ping -c5 fc00::1")
      peer1.succeed("ping -c5 10.23.42.1")
      peer1.succeed("ping -c5 192.168.3.1")
    '';
  }
