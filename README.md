# serverless-report-engine
A Serverless Data-to-Report Engine for Large Datasets (Java + AWS Lambda / GCP Functions)


/serverless-report-engine
    /core
        DataStreamer.java
        ExcelWriter.java
        PdfRenderer.java
    /connectors
        JdbcConnector.java
        S3Connector.java
        GCSConnector.java
    /functions
        AwsLambdaHandler.java
        GcpFunctionHandler.java
    /examples
        sample_sql_query.json
        sample_mapping.json
    /docs
        architecture-diagram.png
        performance-metrics.md
        deployment-guide.md
    README.md

