[Unit]
Description=Sonatype Nexus Repository CE 3.91.0
After=network.target postgresql-16.service
Wants=postgresql-16.service

[Service]
Type=forking
LimitNOFILE=65536
User=${NEXUS_USER}
Group=${NEXUS_GROUP}
ExecStart=${NEXUS_INSTALL_DIR}/bin/nexus start
ExecStop=${NEXUS_INSTALL_DIR}/bin/nexus stop
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
