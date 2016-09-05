#!/bin/env ruby
# encoding: utf-8
# -*- encoding : utf-8 -*-
# Creates a Zabbix IT Services report and sends it by email
#

require 'zabby'
require 'json'
require 'active_support/all'
require 'erb'
require 'inline-style'
require 'slop'
require 'mail'

# Constants
SERVER    = "http://zabbix/zabbix"  # Zabbix server URL
USER      = "zabbixuser"     # Zabbix API user
PASSWORD  = "zabbixpassword"  # Zabbix API password
SERVICE_STATUS = {
  "0" => "OK",
  "1" => "OK",
  "2" => "Warning",
  "3" => "Average",
  "4" => "High",
  "5" => "Disaster"
}.freeze

$datenow = Time.now.to_i
$date1day = 1.day.ago.to_i
$date1week = 1.week.ago.to_i
$date1month = 1.month.ago.to_i

report = []
$maxdepth = 0 # Maximum tree depth

# Messaging parameters
Mail.defaults do
    delivery_method :smtp,  {
    :address => 'mymailserver.domain.local',
    :port => '587',
    :user_name => 'mymailserveruser',
    :password => 'mymailserverpassword',
    :authentication => 'login',
    :enable_starttls_auto => true}
end

# Script parameters
$opts = Slop.new strict: true, help: true do
  banner 'Usage: service_report.rb [options]'

  on :services=,    'A comma-delimited list of services to report', as: Array, delimiter: ',', required: false
  on :from=,        'The mail sender address', as: String, default: 'Monitoring <monitoring@dommain.local>'
  on :to=,          'A comma-delimited list of emails to send the report to', as: Array, delimiter: ',', required: true
  on :title=,       'The title of the report', as: String, required: true
  on :depth=,       'Search depth in the IT Services tree', as: Integer
  on :parentsonly,  'Keep only the parent IT services'
  on :servicetimes, 'Display if service times have been configured'
  on :server=,      'The Zabbix server URL', as: String, default: SERVER
  on :username=,    'The Zabbix server API user', as: String, default: USER
  on :password=,    'The Zabbix server API password', as: String, default: PASSWORD
end

# Parse the parameters
begin
  $opts.parse
rescue Slop::Error => e
  puts e.message
  puts $opts # print help
  exit
end

# For each Zabbix IT service in parameter, parse its dependencies and returns
# an object containing the service and its dependencies
# * *Args*    :
#   - +service+ -> the IT service
#   - +server+  -> the Zabbix server object
#   - +depth+   -> the tree depth
# * *Returns* :
#   - an object with the necessary properties
def iterate_services(service, server, depth)
  obj = get_service(server, service)
  depth = depth - 1

  if depth > 0 # If the max depth has not been reached
    if service['dependencies'] # and the service has dependencies
      service['dependencies'].each do |dep| # parse the dependencies
        begin
          child = server.run {
            Zabby::Service.get(
              'output'=> 'extend',
              'selectDependencies' => 'extend',
              'selectTimes' => 'extend',
              'sortfield' => 'name',
              'sortOrder' => 'ASC',
              'serviceids' => dep['serviceid']
          )}
        rescue Exception => e
          puts e.message
          raise "Impossible to query a dependency of the service %s" % service['name']
        end
        
        if !child[0]['dependencies'].empty? or !$opts.present?(:parentsonly)
          # adds the dependencies to the object
          # if needed
          obj['children'] << iterate_services(child[0], server, depth)
        end
      end
    end
  end
  
  # updates the maxdepth
  $maxdepth = ($opts[:depth] - depth) if (($opts[:depth] - depth) > $maxdepth)  
  return obj
end

# For each Zabbix IT service in parameter, queries for the necessary properties
# * *Args*    :
#   - +service+ -> the IT service
#   - +server+  -> the Zabbix server object
# * *Returns* :
#   - an object with the necessary properties
def get_service(server, service)
	serviceid = service['serviceid']

  begin
    # Gets the availability
    
    # 1 day
    sla1day = server.run {
      Zabby::Service.getsla(
        'output' => 'extend', 
        'serviceids' => serviceid, 
        'intervals' => [ 
          'from' => $date1day, 
          'to' => $datenow 
        ]
    )}
    
    # 1 week
    sla1week = server.run {
      Zabby::Service.getsla(
        'output' => 'extend', 
        'serviceids' => serviceid, 
        'intervals' => [ 
          'from' => $date1week, 
          'to' => $datenow 
        ]
    )}
    
    # 1 month
    sla1month = server.run {
      Zabby::Service.getsla(
        'output' => 'extend', 
        'serviceids' => serviceid, 
        'intervals' => [ 
          'from' => $date1month, 
          'to' => $datenow 
        ]
    )}
    
    # SLA
    slaglobal = server.run {
      Zabby::Service.getsla(
        'intervals' => [ 
          'from' => $date1day, 
          'to' => $datenow 
        ]
    )}
  
    # Gets the current service problems if they exist
    problemids  = slaglobal[serviceid]['problems']
    if !problemids.empty?
      problems = server.run {
        Zabby::Trigger.get(
          'triggerids' => problemids.keys
      )}
    else
      problems = [{'description' => '-'}]
    end
  rescue Exception => e  
    puts e.message
    raise "Impossible to query the properties of the service %s" % service['name']
  end
  
  # Formats the availability values
  goodsla = '%.2f' % service['goodsla'].to_s  
  sla1d   = '%.2f' % sla1day[serviceid]['sla'][0]['sla'].to_s
  sla1w   = '%.2f' % sla1week[serviceid]['sla'][0]['sla'].to_s
  sla1m   = '%.2f' % sla1month[serviceid]['sla'][0]['sla'].to_s
	
  # Returns the object
  return {
    'name'      => service['name'],
    'status'    => service['status'],
    'problems'  => problems.map { |p| p['description'] },
    'sla1d'     => sla1d,
    'sla1w'     => sla1w,
    'sla1m'     => sla1m,
    'goodsla'   => goodsla,
    'showsla'   => service['showsla'],
    'times'     => service['times'].empty? ? 'No' : 'Yes',
    'children'  => []
  }
end


# Formats and displays each row of the table in HTML
# * *Args*    :
#   - +level+ -> the current depth in the tree
#   - +html+  -> the HTML code
#   - +rows+  -> the list of the rows
def iterate_rows(level, html, rows)
  level = level + 1
  rows.each do |r|
    if level == 1
      html << '<tr class="root">' # High level service
    else
      html << '<tr class="child">' # Child service
    end
    if level == 1
      html << '<td colspan=%d>%s</td>' %  [ $maxdepth, r['name'] ]
    else
      # Shifts the child services to the right
      html << '<td class="hidden"></td>' * (level - 1)
      html << '<td colspan=%d class="visible">%s</td>' % [ ($maxdepth - (level - 1)), r['name'] ]
    end
    # Displays the service status in the right color
    html << '<td class="s%d">%s</td>' % [ r['status'], SERVICE_STATUS[r['status']] ]
    
    # The problems list
    html << '<td><table>'
    r['problems'].each do |p|
      p = p + "\n"
      html << '<tr class="problems">%s</tr>' % p
    end
    html << '</table></td>'
    
    # The service times if necessary
    if $opts.present?(:servicetimes)
      html << '<td>%s</td>' % r['times']
    end
    
    # The availability values
    if r['sla1d'].to_f > r['goodsla'].to_f
      html << '<td class="s0">%s</td>' % r['sla1d']
    else
      html << '<td class="s5">%s</td>' % r['sla1d']
    end   
    if r['sla1w'].to_f > r['goodsla'].to_f
      html << '<td class="s0">%s</td>' % r['sla1w']
    else
      html << '<td class="s5">%s</td>' % r['sla1w']
    end 
    if r['sla1m'].to_f > r['goodsla'].to_f
      html << '<td class="s0">%s</td>' % r['sla1m']
    else
      html << '<td class="s5">%s</td>' % r['sla1m']
    end     
    html << '<td>%s</td></tr>' % r['goodsla']
    
    # The child services
    if !r['children'].empty?
      iterate_rows(level, html, r['children'])
    end
  end
  html
end


# Connects to the server
begin
	server = Zabby.init do
	  set :server   => $opts[:server]
	  set :user     => $opts[:username]
	  set :password => $opts[:password]
	  login
	end
rescue Exception => e
  puts e.message
  raise "Impossible to connect to the Zabbix server"
end
	
begin  
  # Gets the services and SLAs  
  services = server.run {
    Zabby::Service.get(
      'output'=> 'extend', 
      'selectDependencies' => 'extend',
      'selectTimes' => 'extend',
      'sortfield' => 'name',
      'sortOrder' => 'ASC',      
      'filter' => { 
        'name' => $opts[:services]
      }
  )}
end
if $opts[:services].present? and (services.length < $opts[:services].length)
  raise "Impossible to get all the IT services in parameter"
end

begin	
  services.each do |service|
    report << iterate_services(service, server, $opts[:depth])
  end
rescue Exception => e
  puts e.message
  raise "Impossible to get all the IT services"
end

# The report ERB template
template = %q{<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
<html lang="en">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
  <title>IT services report</title>
<style type="text/css" media "screen">
* {
    font-family: "Trebuchet MS", Arial, Helvetica, sans-serif;
    border-collapse: collapse;
}

table {
    border: none;
}

tr {
    font-size: 0.9em;
    text-align: center;
    border: none;
    padding: 3px 7px 2px 7px;    
}

td, th {
    font-size: 0.9em;
    text-align: center;
    border: 1px solid #000000;
    padding: 3px 7px 2px 7px;
}

th {
    font-size: 1.0em;
    padding-top: 5px;
    padding-bottom: 4px;
    background-color: #C7114E;
    color: #ffffff;
}

tr.child td.visible {
    font-size: 0.8em;
    width: <%= (10 + $maxdepth*7) / $maxdepth %>%;
}

tr.child td table tr.problems {
    font-size: 0.8em;
}

tr.child td.hidden {
    border: none;
    width: <%= (10 + $maxdepth*7) / $maxdepth %>%;
}

tr.root td:nth-child(1) {
    width: <%= (10 + $maxdepth*7) / $maxdepth %>%;
}

tr.root td {
    color: #000000;
    background-color: #C0C0C0;
}

tr td.s0, tr td.s1 {
    background-color: #88D83B;
}
tr td.s2, tr td.s3 {
    background-color: #F39200;
}
tr td.s4, tr td.s5 {
    background-color: #F15342;
}

footer p {
    font-size: 0.6em;
}


</style>
</head>
<body>
  <div id="body">
    <table>
      <tr>
        <th colspan=<%= $maxdepth %>>Service</th>
        <th>Status</th>		
        <th>Current problems</th>
        <% if $opts.present?(:servicetimes) %>
          <th>Configured service times ?</th>
        <% end %>
        <th>Availability (% 1 day)</th>
        <th>Availability (% 1 week)</th>
        <th>Availability (% 1 month)</th>
        <th>SLA (%)</th>
      </tr>
      <% html = '' %>
      <% level = 0 %>
      <%= iterate_rows(level, html, report) %>
    </table>
  </div>	
  <footer>
    <p><%= Time.now.strftime('Report created on %m/%d/%Y %H:%M.') %></p>
  </footer>
</html>
}

# Generate the HTML code
htmlreport = ERB.new(template).result

# Sends the message by email
begin
  mail = Mail.new do
    charset = 'UTF-8'
    content_type 'text/html; charset=UTF-8'
    
    from     $opts[:from]
    to       $opts[:to].join(',')
    subject  $opts[:title]
    body     InlineStyle.process(htmlreport, :stylesheets_paths => "./styles")
  end

  mail.deliver  
rescue Exception => e
  puts e.message
  raise "Impossible to send the report"
end

exit 0
__END__

