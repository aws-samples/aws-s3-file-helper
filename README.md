## AWS S3 File Helper

This Shell Script helps to copy text files and perform some basic transformation with the following parameters:

    --jobname=         REQUIRED. A job name with no spaces and special characters. Example : daily_transactions
    --env=             REQUIRED. Environment to run in (dev, e2e, prd, prf)
    --files=           REQUIRED. Files to copy
    --days=            OPTIONAL. Iterates {date} variable for Last d days. 
                                 If -d not provided {date} = today.  -d 1 = today, -d 2 = yesterday and today
    --output_format=   OPTIONAL. Default = gz . File output format. Available options : gz, csv
    --output_location= REQUIRED. File output target S3 location. Example : s3://my_s3_bucket/my_target_prefix/
    --removefirst=     OPTIONAL. Removes first x lines from the file
    --removelast=      OPTIONAL. Removes last x lines from the file
    --removeheader     OPTIONAL. Removes header line (no param value is needed)
    --addheader        OPTIONAL. Adds the header line to each split files (no param value is needed)
    --mergefiles       OPTIONAL. Merges small files into a large file
    --splitrows=       OPTIONAL. Max number of rows you want in each file

   Examples :
   
    sh filecopy.sh
    --jobname=daily_transactions
    --env=prd
    --files='/data/folder/subfolder/Fileprefix_{date}*tar.gz'
    --days=1
    --output_format=csv
    --output_location='/data2/anothersubfolder/'
    --splitrows=500000
    --addheader
  
    sh filecopy.sh
    --jobname=daily_transactions
    --env=prd
    --files='/data/folder/subfolder/Fileprefix_{date}*zip'
    --days=10
    --output_format=gz
    --output_location='s3://mybucket/myprefix/'
    --removefirst=1
    --removelast=1
    --removeheader
    --mergefiles



## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

