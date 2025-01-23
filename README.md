*Błażej Nowicki, Ewa Pelc*

# Manipulating Delta Lake tables on MinIO with Trino.

This repository contains a step-by-step implementation of a open-source DataLake architecture using Docker Compose and Helm Charts. It serves as a guide for developers who want to understand the journey of designing and deploying a DataLake solution.

Used technologies: Trino, Minio, Hive Metastore, Postgres, Docker, Kubernetes, Helm, CloudNativePG

![](assets/datalake.png)

Table of contents:

- [Quickstart](#quickstart)
- [How we got here (Docker Compose)](#how-we-got-here)
  - [Hive Metastore](#hive-metastore)
  - [Minio](#minio)
  - [Trino](#trino)
  - [Testing](#testing)
  - [Refactoring](#refactor)
- [Helm Chart](#helm-chart)
  - [Prerequisites](#prerequisites)
  - [Directory structure](#directory-structure)
  - [Postgres](#postgres)
  - [Hive Metastore](#hive-meastore-1)
  - [Trino](#trino-1)
  - [Deployment and testing](#deployment-steps-and-testing)

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

## How we got here

This guide outlines the process of designing and implementing data lake architecture with the following components:

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

### Minio

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

### Trino

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

### Refactoring

At this point we have a working setup.

Before we move on to deploying it on kubernetes let's reorganize it a bit.

Repository structure:
- `docker-compose`
  - `metastore` - directory with config files for Hive
  - `trino` - directory with config files for Trino
  - `docker-compose.yaml` - Docker Compose file
- `images` - directory for custom images used in the project
  - `hive-metastore` - Hive Metastore image

This changes path names used in the `docker-compose.yaml` file but everything else stays the same.

## Helm Chart

This section describes the steps taken to deploy the stack on kubernetes. 
For local testing we will use Minikube.
Kubernetes resources will be deployed with Helm Charts.

- For Postgres we can use [CloudNativePG](https://cloudnative-pg.io/)
- For Hive we can use the custom image we defined earlier and define kubernetes templates based on the docker compose file.
- For Trino we can use the official Trino Helm Chart by declaring it a dependency and by providing configuration values

### Prerequisites
1. Install [Minikube](https://minikube.sigs.k8s.io/docs/start/?arch=%2Fwindows%2Fx86-64%2Fstable%2F.exe+download). Minikube allows you to run Kubernetes locally.
2. Install [Helm](https://helm.sh/docs/intro/install/). Helm is a package manager for Kubernetes, used to deploy applications via "charts."
3. Verify the installations by checking their versions:
   ```bash
   minikube version
   helm version
   ```

### Directory Structure

- `templates/` - place for custom k8s templates
  - `...`
- `Chart.yaml` - chart's name, version etc.
- `values.yaml` - configuration values 

`Chart.yaml`
```
apiVersion: v2
name: data-lake
description: A Helm chart for a Data Lake (Trino + Hive Metastore + PostgreSQL)
type: application
version: 0.1.0
dependencies:
  ...
```

### Postgres

We will be using [CloudNativePG](https://cloudnative-pg.io/) ([Docs](https://cloudnative-pg.io/documentation/1.25/))

First we need to install the extension on the cluster:

```
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml
```

To set credentials for the hive user we need to create a secret. 
Values for that secret we can set in `values.yaml`

`values/.yaml`

```yaml
postgres:
  username: hive
  password: password
  database: metastore_db
```

`templates/postgres-secret.yaml`

```yaml
apiVersion: v1
kind: Secret
type: kubernetes.io/basic-auth
data:
  username: {{ .Values.postgres.username | b64enc }}
  password: {{ .Values.postgres.password | b64enc }}
metadata:
  name: app-secret
  labels:
    app: hive-metastore
```

Note that username and password need to be base64 encoded in the template

For the cluster definition:

`templates/postgres-cluster.yaml`
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  labels:
    app: hive-metastore
spec:
  instances: 1
  bootstrap:
    initdb:
      database: {{ .Values.postgres.database }}
      owner: {{ .Values.postgres.username }}
      secret:
        name: app-secret
  storage:
    size: 1Gi
```

### Hive Metastore

We need to create service and deployment. We can create config map with contents of `core-site.xml` and mount it as a volume in the right directory. 

Note that we are disabling ssl to avoid errors. This is not a proper solution but let's leave it for now.

`template/metastore-service.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: hive-metastore
  labels:
    app: hive-metastore
spec:
  ports:
  - port: 9083
    targetPort: 9083
  selector:
    app: hive-metastore
```

`template/metastore-service.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hive-metastore
  labels:
    app: hive-metastore
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hive-metastore
  template:
    metadata:
      labels:
        app: hive-metastore
    spec:
      containers:
      - name: hive-metastore
        image: nowickib/hive-metastore:latest
        ports:
        - containerPort: 9083
        env:
        - name: SERVICE_NAME
          value: metastore
        - name: DB_DRIVER
          value: postgres
        - name: SERVICE_OPTS
          value: |
            -Djavax.jdo.option.ConnectionDriverName=org.postgresql.Driver
            -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://{{ .Values.metastore.postgres.host }}:5432/{{ .Values.metastore.postgres.database }}?sslmode=disable
            -Djavax.jdo.option.ConnectionUserName={{ .Values.metastore.postgres.username }}
            -Djavax.jdo.option.ConnectionPassword={{ .Values.metastore.postgres.password }}
        volumeMounts:
        - name: hadoop-config
          mountPath: /opt/hadoop/etc/hadoop/core-site.xml
          subPath: core-site.xml
      volumes:
      - name: hadoop-config
        configMap:
          name: hadoop-config
```

`template/metastore-config-map.yaml`
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hadoop-config
  labels:
    app: hive-metastore
data:
  core-site.xml: |
    <?xml version="1.0" encoding="UTF-8"?>
    <?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
    ...
    </configuration>
```

Note that we are using publicly available image that we created that is hosted on DockerHub. If you'd like you can [build](https://docs.docker.com/get-started/introduction/build-and-push-first-image/) that image yourself and change this line 
```yaml
- name: hive-metastore
  image: nowickib/hive-metastore:latest # <---
``` 


### Trino

We can reuse the official helm chart for Trino ([Docs](https://trino.io/docs/current/installation/kubernetes.html))

`Chart.yaml`

```yaml
...
dependencies:
  - name: trino
    version: 1.35.0 
    repository: "https://trinodb.github.io/charts"
```

`values.yaml`   

Overrides default configuration, customizing catalogs for this setup.

```yaml
trino:
  catalogs:
    delta: |-
      connector.name=delta_lake
      hive.metastore=thrift
      hive.metastore.uri=thrift://hive-metastore:9083
      fs.native-s3.enabled=true
      s3.path-style-access=true
      s3.endpoint=http://host.minikube.internal:9000
      s3.aws-access-key=user
      s3.aws-secret-key=password
      s3.region=us-east-1

    hive: |-
      connector.name=hive
      hive.metastore.uri=thrift://hive-metastore:9083      
      fs.native-s3.enabled=true
      s3.path-style-access=true
      s3.endpoint=http://host.minikube.internal:9000
      s3.aws-access-key=user
      s3.aws-secret-key=password
      s3.region=us-east-1
      hive.non-managed-table-writes-enabled=true
```
- Configures catalogs for Delta Lake and Hive.
- `host.minikube.internal`: Allows services in Minikube to communicate with those in Docker Compose.
- Postgres is not directly referenced in Trino because it serves as the backend for Hive Metastore and not Trino itself.


### Deployment steps and testing

If you encounter any errors consider that there might be state desynchronization between the metastore and minio
i.e. consider having a definition of a table in Hive while the bucket is missing.
To fix this you can, for example, delete existing volumes related to docker compose and kubernetes or do something smarter.


1. **Start Docker Compose Services**  
   Start Minio in Docker Compose

   ```bash
   docker compose up minio mc
   ```

   Note: Add `mc` only when the test bucket hasn't been created yet.

2. **Start Minikube**  
    Ensure that Docker Desktop is running and launch Minikube with sufficient resource allocations:

    ```bash
    minikube start --memory=6g --cpus=3 --driver=docker
    ```
  - `memory=6g`: Allocates 6GB of memory.
  - `cpus=3`: Allocates 3 CPU cores.
  - `driver=docker`: Uses Docker as the virtualization driver.

3. **Check Minikube Status**  
    Verify that Minikube is running:

    ```bash
    minikube status
    ```

    The result should look as follows:   

    ![minikube_status](assets/minikube_status.png)

4. **Deploy CloundNativePG's controller**  

    ```
    kubectl apply --server-side -f \
      https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml
    ```

    and verify

    ```
    kubectl get deployment -n cnpg-system cnpg-controller-manager
    ```

5. **Install dependencies**   

    ```
    helm dependency update
    ```

6. **Install the Helm Chart on the cluster**

    ```bash
    helm install -f values.yaml data-lake .
    ```

7. **Check Pod Status**   
    Confirm that all resources are in the `READY` state. Note that this process may take a few minutes:

    ```bash
    kubectl get all
    ```

    The result should look as follows:   

    ```
    ❯ kubectl get all
    NAME                                              READY   STATUS    RESTARTS      AGE
    pod/data-lake-trino-coordinator-8cbb75dc7-bmltb   1/1     Running   0             50m
    pod/data-lake-trino-worker-78c47f455c-5fzh6       1/1     Running   0             50m
    pod/data-lake-trino-worker-78c47f455c-k5dmc       1/1     Running   0             50m
    pod/hive-metastore-74cbb56759-hsws2               1/1     Running   1 (50m ago)   50m
    pod/postgres-1                                    1/1     Running   0             50m

    NAME                             TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
    service/data-lake-trino          ClusterIP   10.109.55.166    <none>        8080/TCP   50m
    service/data-lake-trino-worker   ClusterIP   None             <none>        8080/TCP   50m
    service/hive-metastore           ClusterIP   10.111.90.86     <none>        9083/TCP   50m
    service/kubernetes               ClusterIP   10.96.0.1        <none>        443/TCP    79m
    service/postgres-r               ClusterIP   10.107.1.4       <none>        5432/TCP   50m
    service/postgres-ro              ClusterIP   10.108.161.111   <none>        5432/TCP   50m
    service/postgres-rw              ClusterIP   10.104.98.157    <none>        5432/TCP   50m

    NAME                                          READY   UP-TO-DATE   AVAILABLE   AGE
    deployment.apps/data-lake-trino-coordinator   1/1     1            1           50m
    deployment.apps/data-lake-trino-worker        2/2     2            2           50m
    deployment.apps/hive-metastore                1/1     1            1           50m

    NAME                                                    DESIRED   CURRENT   READY   AGE
    replicaset.apps/data-lake-trino-coordinator-8cbb75dc7   1         1         1       50m
    replicaset.apps/data-lake-trino-worker-78c47f455c       2         2         2       50m
    replicaset.apps/hive-metastore-74cbb56759               1         1         1       50m
    ```

8. **Forward Ports**   
    Forward the Trino service port to access the Trino Web UI locally:

    ```bash
    kubectl port-forward service/data-lake-trino 8080:8080
    ```

    This is necessary because Trino is running inside Minikube, and port forwarding allows local access to the Trino Web UI.

9. **Access the Trino Web UI**  
    Open your browser and go to `http://127.0.0.1:8080`.


10. **Connect to Trino Using SQL Client**   
    Use a SQL client application (e.g., DataGrip) to connect to Trino for querying.

    ![trino_datasource](assets/trino_datasource.png)


11. **Test Table Creation**   
    Create tables in Trino and verify their presence in Minio (S3-compatible storage) to ensure the setup works as expected.

    ```sql
    CREATE SCHEMA IF NOT EXISTS delta.iris
    WITH (location = 's3a://iris/');

    CREATE TABLE delta.iris.minikube_test (
        id INT,
        name VARCHAR,
        age INT
    )
    WITH (location = 's3a://iris/minikube_test/');

    INSERT INTO delta.iris.minikube_test (id, name, age) VALUES
        (1, 'Alice', 30),
        (2, 'Bob', 25);

    SELECT * FROM delta.iris.minikube_test;
    ```

11. **Access Minio**   
    Open your browser and navigate to the Minio Console `http://localhost:9001` to verify that the Delta table has been created successfully.
