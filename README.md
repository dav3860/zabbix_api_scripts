# zabbix_api_scripts
This is a collection of Ruby scripts using the Zabbix API
### copy_time_periods.zby
This script will copy a Zabbix IT service time periods to another IT service.
### create_it_services.zby
This script will create zabbix IT services based on a host triggers.
### delete_items.zby
This script will delete zabbix items based on a search filter.
### propagate_slas.zby
This script will propagate a Zabbix IT service SLAs to its children.
### propagate_time_periods.zby
This script will propagate a Zabbix IT service time periods to its children.
### service_report.rb
Creates a Zabbix IT Services report and sends it by email.
## Installation
Clone the repository. Run "bundle" to install the required gems and configure the ~/.zabbyrc file with your Zabbix server configuration (see https://github.com/Pragmatic-Source/zabby). 

The service_report.rb script requires the following parameters to be set in the file : 
``` 
SERVER = "http://zabbix/zabbix" # Zabbix server URL 
USER = "zabbixuser" # Zabbix API user 
PASSWORD = "zabbixpassword" # Zabbix API password 
[...]
    :address => 'mymailserver.domain.local', port => '587', user_name => 'mymailserveruser', password => 'mymailserverpassword',
[...]
  on :from=, 'The mail sender address', as: String, default: 'Monitoring <monitoring@dommain.local>' ```
