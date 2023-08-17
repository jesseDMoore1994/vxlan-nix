
{ nixosTest, nixosModule, pkgs, lib }:
let
  wg-snakeoil-keys = import ./snakeoil-keys.nix;
  peer = (import ./make-peer.nix) { inherit lib; };
  peer0-vxlan-orchestration = {
    path = [ pkgs.git pkgs.iproute2 pkgs.nettools pkgs.nix ];
    script = with pkgs; ''
      #!/usr/bin/env nix-shell
      #!nix-shell -i bash

      ${iproute2}/bin/ip address add dev br0 10.23.43.1/24
      ${iproute2}/bin/ip link add peer1    type vxlan remote 10.23.42.2 id 1 dstport 4789

    '';

    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    wantedBy = [ "multi-user.target" ];
    after = ["wireguard-wg0.service"];
  };
  peer1-vxlan-orchestration = {
    path = [ pkgs.git pkgs.iproute2 pkgs.nettools pkgs.nix ];
    script = with pkgs; ''
      #!/usr/bin/env nix-shell
      #!nix-shell -i bash

      ${iproute2}/bin/ip address add dev br0 10.23.43.2/24
      ${iproute2}/bin/ip link add peer0    type vxlan remote 10.23.42.1 id 1 dstport 4789
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    wantedBy = [ "multi-user.target" ];
    after = ["wireguard-wg0.target"];
  };
in
  nixosTest {
    name = "vxlan-nix";
    nodes = {
      peer0 = peer {
        ip4 = "192.168.0.1";
        ip6 = "fd00::1";
        extraConfig = {
          networking.firewall.allowedUDPPorts = [ 23542 ];
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
            path = [ pkgs.git pkgs.iproute2 pkgs.nettools pkgs.nix ];
            enable = true;
            script = with pkgs; ''
              #!/usr/bin/env nix-shell
              #!nix-shell -i bash

              ${iproute2}/bin/ip link add name br0 type bridge stp_state 1
              ${iproute2}/bin/ip address add dev br0 10.23.43.1/24
              ${iproute2}/bin/ip link add peer1    type vxlan remote 10.23.42.2 id 1 dstport 4789
              ${iproute2}/bin/ip link set up peer1
              ${iproute2}/bin/ip link set peer1 master br0

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
            path = [ pkgs.git pkgs.iproute2 pkgs.nettools pkgs.nix ];
            enable = true;
            script = with pkgs; ''
              #!/usr/bin/env nix-shell
              #!nix-shell -i bash

              ${iproute2}/bin/ip link add name br0 type bridge stp_state 1
              ${iproute2}/bin/ip address add dev br0 10.23.43.2/24
              ${iproute2}/bin/ip link add peer0    type vxlan remote 10.23.42.1 id 1 dstport 4789
              ${iproute2}/bin/ip link set up peer0
              ${iproute2}/bin/ip link set peer0 master br0

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
      peer1.succeed("ping -c5 10.23.43.1")
    '';
  }
