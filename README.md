# Minio + Trino + Delta tables

## Quickstart

**Docker compose**

```
docker compose up
```

Use any compatible SQL client application that is listed in the [docs](https://trino.io/ecosystem/index.html)

**Example using DBeaver**

Add new source

![dbeaver](assets/dbeaver_config.png)

Open SQL console

![open sql console](assets/open_sql.png)

Run all queries

![query example](assets/query_example.png)


```sql
CREATE SCHEMA IF NOT EXISTS hive.iris
    WITH (location = 's3a://iris/');

CREATE TABLE IF NOT EXISTS hive.iris.iris_parquet
(
    sepal_length DOUBLE,
    sepal_width  DOUBLE,
    petal_length DOUBLE,
    petal_width  DOUBLE,
    class        VARCHAR
)
WITH (format = 'PARQUET');

INSERT INTO hive.iris.iris_parquet (select random() as sepal_length, random() as sepal_width, random() as petal_length, random() as petal_widths, cast(random(1, 3) as varchar) as class  from unnest(sequence(1,10)));

SELECT * FROM hive.iris.iris_parquet;
```

## Process

This guide outlines the process of designing and implementing a data lake architecture using the following components:

- Metastore: Hive Metastore
- SQL Engine: Trino
- Object Storage: MinIO
- Table Format: Delta Tables

The initial setup will use Docker Compose for local testing, with plans to migrate to Kubernetes for production deployment.

### Hive metastore

See [setup instructions](https://hive.apache.org/development/quickstart/#:~:text=%2D-,Metastore,-For%20a%20quick)


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

Next step is to convert docker-run commands to `docker-compose.yaml`. Before we do that  let's customize the hive image so that we don't have to download the jar manually.
The file can be downloaded from the [maven repository](https://mvnrepository.com/artifact/org.postgresql/postgresql/42.5.1)

```Dockerfile
FROM apache/hive:4.0.0

ADD --chmod=644 https://repo1.maven.org/maven2/org/postgresql/postgresql/42.5.1/postgresql-42.5.1.jar /opt/hive/lib/postgres.jar
```

Now we can once again update the star-up command

```
docker run -it --rm -p 9083:9083 --env SERVICE_NAME=metastore --env DB_DRIVER=postgres --network host \
   --env SERVICE_OPTS="-Djavax.jdo.option.ConnectionDriverName=org.postgresql.Driver -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://localhost:5432/metastore_db -Djavax.jdo.option.ConnectionUserName=hive -Djavax.jdo.option.ConnectionPassword=password" \
   --mount source=warehouse,target=/opt/hive/data/warehouse \
   --name metastore-standalone $(docker build -q .)
```

**Docker Compose**

Let's collect what we've done so far in a docker-compose file

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

  hive-metastore:
    build: .
    hostname: metastore
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
      MINIO_ROOT_USER: user
      MINIO_ROOT_PASSWORD: password
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

Based on the documentation we need to create configuration files. We can use the default values for now.

Deployment config:
- `config.properties`
- `jvm.properties`
- `log.properties`
- `node.properties`

Data catalogs:
- `hive.properties`

Simplest start-up command
```
docker run --name trino -d -p 8080:8080 --volume $PWD/etc:/etc/trino trinodb/trino
```

As service in docker compose: 
```yaml
trino:
  image: trinodb/trino:latest
  ports:
    - "8080:8080"
  volumes:
    - ./trino:/etc/trino
  networks:
    - trino_network
  depends_on:
    - minio
    - hive-metastore
  restart: unless-stopped
```
For testing we can use any Trino client listed in the docs. I'm using executable JAR file with Trino CLI.

```
./trino.jar http://localhost:8080
```

For testing I will be using SQL queries from similar tutorial [link](https://fithis2001.medium.com/manipulating-delta-lake-tables-on-minio-with-trino-74b25f7ad479)

![test bucket](assets/test_bucket.png)

We can also automate it for future deployments by adding `minio/mc` util to the `docker-compose.yaml` file.

```yaml
  mc:
    depends_on:
      - minio
    image: minio/mc
    container_name: mc
    entrypoint: >
      /bin/sh -c "
      until (/usr/bin/mc config host add minio http://minio:9000 user password) do echo '...waiting...' && sleep 1; done;
      /usr/bin/mc rm -r --force minio/iris;
      /usr/bin/mc mb minio/iris;
      /usr/bin/mc policy set public minio/iris;
      exit 0;
      "
    networks:
      - trino_network
```

```sql
CREATE SCHEMA IF NOT EXISTS hive.iris
    WITH (location = 's3a://iris/');

CREATE TABLE IF NOT EXISTS hive.iris.iris_parquet
(
    sepal_length DOUBLE,
    sepal_width  DOUBLE,
    petal_length DOUBLE,
    petal_width  DOUBLE,
    class        VARCHAR
)
WITH (format = 'PARQUET');

INSERT INTO hive.iris.iris_parquet (select random() as sepal_length, random() as sepal_width, random() as petal_length, random() as petal_widths, cast(random(1, 3) as varchar) as class  from unnest(sequence(1,10)));

SELECT * FROM hive.iris.iris_parquet;
```




When attempting to create schema we get a dependency error. 

![dependency error](assets/dependency_error.png)

The error is displayed in the Trino's console but after some research I found out it's actually hive related.

The resolution is to add S3 drivers to the metastore image.

```Dockerfile
FROM apache/hive:4.0.0

# Postgres Driver
ADD --chmod=644 https://repo1.maven.org/maven2/org/postgresql/postgresql/42.5.1/postgresql-42.5.1.jar /opt/hive/lib/postgres.jar

# S3 Drivers
ADD --chmod=644 https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.11.1026/aws-java-sdk-bundle-1.11.1026.jar /opt/hive/lib/aws-java-sdk-bundle-1.11.1026.jar
ADD --chmod=644 https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.2/hadoop-aws-3.3.2.jar /opt/hive/lib/hadoop-aws-3.3.2.jar
```

Now we get missing credentials error. Again it's hive related and we need to create `core-site.xml` with minio credentials and mount it in `/opt/hadoop/etc/hadoop/core-site.xml`

![missing credentials](assets/missing_credentials.png)


### Testing

For testing you can use any client application listed on the Trino's website.

Example configuration for DBeaver

![dbeaver](assets/dbeaver_config.png)
![dbeaver](assets/dbeaver.png)