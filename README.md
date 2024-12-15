# Minio + Trino + Delta tables


### Overview

I will describe here the whole process of designing the final solution.

High level purpose of this experiment is to test data lake architecture with the following components:
 - SQL enigne: Trino
 - Storage: Minio
 - Table format: Delta tables

### Process

The plan is to start with docker compose setup and then migrate to kubernetes.

**Collecting requirements**

I started from the most high-level component to determine what we need to configure. In our case that would be Trino


First takeaway from the documentation is that we need to also deploy hive metastore first. So let's do that first

**Hive metastore**

Setup instructions:
https://hive.apache.org/development/quickstart/#:~:text=%2D-,Metastore,-For%20a%20quick


Original: 
```
docker run -d -p 9083:9083 --env SERVICE_NAME=metastore --env DB_DRIVER=postgres \
   --env SERVICE_OPTS="-Djavax.jdo.option.ConnectionDriverName=org.postgresql.Driver -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://postgres:5432/metastore_db -Djavax.jdo.option.ConnectionUserName=hive -Djavax.jdo.option.ConnectionPassword=password" \
   --mount source=warehouse,target=/opt/hive/data/warehouse \
   --mount type=bind,source=`mvn help:evaluate -Dexpression=settings.localRepository -q -DforceStdout`/org/postgresql/postgresql/42.5.1/postgresql-42.5.1.jar,target=/opt/hive/lib/postgres.jar \
   --name metastore-standalone apache/hive:${HIVE_VERSION}
```

Modified:
 - use don't use `mvn` to find jar with Postgres driver
 - hardcode hive version
 - use `--network=host` to be able to reach the DB
 - add `pwd` to get absolute path to bind command
  
I manually downloaded: `postgresql-42.5.1.jar`

```
docker run -it -p 9083:9083 --env SERVICE_NAME=metastore --env DB_DRIVER=postgres --network host \
   --env SERVICE_OPTS="-Djavax.jdo.option.ConnectionDriverName=org.postgresql.Driver -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://localhost:5432/metastore_db -Djavax.jdo.option.ConnectionUserName=hive -Djavax.jdo.option.ConnectionPassword=password" \
   --mount source=warehouse,target=/opt/hive/data/warehouse \
   --mount type=bind,source=`pwd`/postgresql-42.5.1.jar,target=/opt/hive/lib/postgres.jar \
   --name metastore-standalone apache/hive:4.0.0
```

Before we run it we need to create postgres instance:

```
docker run -it --rm \
  -e POSTGRES_USER=hive \
  -e POSTGRES_PASSWORD=password \
  -e POSTGRES_DB=metastore_db \
  -p 5432:5432 \
  postgres
```

```
docker run -it --rm \
  --name psql-client \
  --network host \
  postgres \
  psql -h localhost -U hive -d metastore_db
```

It seems to work as expected. Schema is initialized and no errors occurred.

Next step is converting to docker compose but before that let's customize the hive image so that we don't have to down load the jar manually.
We will be downloading the jar file from the [maven repository](https://mvnrepository.com/artifact/org.postgresql/postgresql/42.5.1)

```Dockerfile
FROM apache/hive:4.0.0

ADD --chmod=644 https://repo1.maven.org/maven2/org/postgresql/postgresql/42.5.1/postgresql-42.5.1.jar /opt/hive/lib/postgres.jar
```

(Side-note) Some nice debugging commands:
```
docker run -it --entrypoint /bin/bash $(docker build -q .)
```

Then we can once again update the star-up command

```
docker run -it --rm -p 9083:9083 --env SERVICE_NAME=metastore --env DB_DRIVER=postgres --network host \
   --env SERVICE_OPTS="-Djavax.jdo.option.ConnectionDriverName=org.postgresql.Driver -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://localhost:5432/metastore_db -Djavax.jdo.option.ConnectionUserName=hive -Djavax.jdo.option.ConnectionPassword=password" \
   --mount source=warehouse,target=/opt/hive/data/warehouse \
   --name metastore-standalone $(docker build -q .)
```

**Docker Compose**

Let's collect what we've done so far in a docker compose file

```yaml
services:
  postgres:
    image: postgres
    environment:
      POSTGRES_USER: hive
      POSTGRES_PASSWORD: password
      POSTGRES_DB: metastore_db
    ports:
      - "5432:5432"
    networks:
      - metastore_network
    restart: unless-stopped

  metastore:
    build: .
    environment:
      SERVICE_NAME: metastore
      DB_DRIVER: postgres
      SERVICE_OPTS: |
        -Djavax.jdo.option.ConnectionDriverName=org.postgresql.Driver
        -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://postgres:5432/metastore_db
        -Djavax.jdo.option.ConnectionUserName=hive
        -Djavax.jdo.option.ConnectionPassword=password
    ports:
      - "9083:9083"
    volumes:
      - warehouse:/opt/hive/data/warehouse
    networks:
      - metastore_network
    depends_on:
      - postgres
    restart: unless-stopped

networks:
  metastore_network:
    driver: bridge

volumes:
  warehouse:
    driver: local
```

**Minio**

In the final deployment on Kubernetes we will use an external Minio deployment that will be provided to us. 
For the testing purposes we want to have our own instance.

Based on [docs](https://min.io/docs/minio/container/index.html#procedure)

```
docker run \
   -p 9000:9000 \
   -p 9001:9001 \
   -v data:/data \
   -e "MINIO_ROOT_USER=user" \
   -e "MINIO_ROOT_PASSWORD=password" \
   quay.io/minio/minio server /data --console-address ":9001"
```

We can test it by visiting `http://127.0.0.1:9001/browser` and update `docker-compose.yaml`

```yaml
services:
  postgres:
    image: postgres
    environment:
      POSTGRES_USER: hive
      POSTGRES_PASSWORD: password
      POSTGRES_DB: metastore_db
    ports:
      - "5432:5432"
    networks:
      - metastore_network
    restart: unless-stopped

  metastore:
    build: .
    environment:
      SERVICE_NAME: metastore
      DB_DRIVER: postgres
      SERVICE_OPTS: |
        -Djavax.jdo.option.ConnectionDriverName=org.postgresql.Driver
        -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://postgres:5432/metastore_db
        -Djavax.jdo.option.ConnectionUserName=hive
        -Djavax.jdo.option.ConnectionPassword=password
    ports:
      - "9083:9083"
    volumes:
      - metastore:/opt/hive/data/warehouse
    networks:
      - metastore_network
      - trino_network
    depends_on:
      - postgres
    restart: unless-stopped
  
  minio:
    image: 'quay.io/minio/minio:latest'
    environment:
      MINIO_ROOT_USER: minio_access_key
      MINIO_ROOT_PASSWORD: minio_secret_key
    ports:
      - '9000:9000'
      - '9001:9001'
    volumes:
      - datalake:/data
    command: server /data --console-address ":9001"
    networks:
      - trino_network
    restart: unless-stopped

networks:
  metastore_network:
    driver: bridge

  trino_network:
    driver: bridge

volumes:
  metastore:
    driver: local

  datalake:
    driver: local
```

**Trino**

Reading list:
- Overview
  - [Use cases](https://trino.io/docs/current/overview/use-cases.html)
  - [Concepts https](trino.io/docs/current/overview/concepts.html)
- Connector related stuff
  - [Hive connector](https://trino.io/docs/current/connector/hive.html)
  - [Minio stuff](https://trino.io/docs/current/object-storage/file-system-s3.html)
- Deployment related stuff
  - [Node config][https://trino.io/docs/current/installation/deployment.html#]
  - [Docker deployment](https://trino.io/docs/current/installation/containers.html#)

TODO catalog configs...

Simplest start-up command
```
docker run --name trino -d -p 8080:8080 --volume $PWD/etc:/etc/trino trinodb/trino
```

As service in docker compose: 
```yaml
trino:
  image: trinodb/trino:390
  ports:
    - "8080:8080"
  volumes:
    - ./trino:/etc/trino
  networks:
    - trino_network
  depends_on:
    - minio
    - metastore
  restart: unless-stopped
```

I tried to use the latest images but I kept getting low level java errors. Might architecture related but I didn't check.
I rolled back to the version described in the documentation.

