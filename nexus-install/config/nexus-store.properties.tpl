# ============================================================
# nexus-store.properties
# PostgreSQL 데이터베이스 연결 설정
# 위치: ${NEXUS_DATA_DIR}/etc/fabric/nexus-store.properties
# ============================================================

name=nexus
type=jdbc
jdbcUrl=jdbc:postgresql://localhost:${PG_PORT}/${PG_DB_NAME}
username=${PG_DB_USER}
password=${PG_DB_PASSWORD}
maximumPoolSize=100
