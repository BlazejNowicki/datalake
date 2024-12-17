FROM apache/hive:4.0.0

# Postgres Driver
ADD --chmod=644 https://repo1.maven.org/maven2/org/postgresql/postgresql/42.5.1/postgresql-42.5.1.jar /opt/hive/lib/postgres.jar

# S3 Drivers
ADD --chmod=644 https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.11.1026/aws-java-sdk-bundle-1.11.1026.jar /opt/hive/lib/aws-java-sdk-bundle-1.11.1026.jar
ADD --chmod=644 https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.2/hadoop-aws-3.3.2.jar /opt/hive/lib/hadoop-aws-3.3.2.jar