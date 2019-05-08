#!/usr/bin/env ruby

=begin

TODO 
-] possibility of sorting results per log date [-s]
-] possibility of augmenting the search results [-l] 
-] possibility of restricting the date for the search [-d]

=end 


require 'json'
require 'date'

# require 'pry'


doc = <<HERED

<b>NAME</b>
elastico -- search and display loglines from Elasticsearch.

<b>SYNOPSIS</b>
$> elastico -h | less -R           # read this manual 
$> elastico [-l num] [-s] [-h|H] QUERY

<b>DESCRIPTION</b>
The fastest way to start to use this program is to read 
the examples section at the end of this document.

The syntax of the QUERY is the so called "Lucene Query Syntax".
It is almost indentical of the one accpeted by Kibana interface. 

By default the search is made into the "lclslogs" index, 
that is, we search into all log files lines stored in "psmetric01:/u2/logs"
and processed by Elasticsearch.

By default the search is made into the "src" field of each document.
The field contains the log line as red from 'psmetric01:/u2/logs/*/*' .

At the time of writing this text the "lclslogs" index contains
the following fields: 
<b>date</b>    : date appearing in the logfile, extended to contain a guessed 
                 value for the year.  
<b>machine</b> : Machine producing the message. 
          (eg. psmetric01, psana101 etc. )
<b>service</b> : Service producing the message. 
          (eg. cron, 
<b>message</b> : The message part of a log line. 
          (eg. "Cannot create socket to [psmonit]:8020 -- Connection refused")
<b>file</b>    : Logfile name where the message was found: 
          (eg. messages, cron, etc. )
<b>src</b>     : To simplify the search by shell this field was added in a second
          phase. It contains the log line as it is recorded in 'psmetric01:/u2/logs/*/*'.
          eg:
 "Dec  5 14:57:27 psana1507 monit[6494]: Cannot create socket to [psmonit]:8020 -- Connection refused"  

<b>PARAMETERS</b>

   <b>NOTE</b>. For all boolean parameters, that is parameters enabling or disabling a 
         feature, an upcase character means the opposite of its correspondant 
         lowercase character. Example: '-S' has the opposite effect of '-s'.

   <b>-l</b>  Maximum number of <b>lines</b> to retrive from Elasticsearch. It must
       be a positive integer. Default to 20.

   <b>-h</b>  If given as the only parameter then the program will output 
       the documentation. If there are other parameters then the 
       matched words in output will be <b>highlight</b>ed. Words 
       of specific fields as e.g. machine:foo will not be highlithed,
       it only applies to the default <b>src</b> field. Default to false.

   <b>-s</b>  Asks Elasticsearch to sort the result not by relevence, as its 
       default but by time. Default to true.


<b>EXAMPLES</b>

# Generic search over a word ... here a machine name 
.b $> elastico psana101        

# Generic search over a word ... here a service name 
.b $> elastico monit           

# Generic search over a wors ... here a user name    
.b $> elastico nmingott        

# Generic search over an approximate username 
# Quote is necessary because "~" is special in bash.
.b $> elastic 'omar~'

# Generic search over everything that can be: psana101, psana103 etc.
# observe that the quotes are fundamental to stop Bash from interpreting
# "*". 
.b $> elastico 'psana*'        

# Search all log lines where there appear the work "nmingott" somwhere
# AND the machine is a string which contains "metric".
# Booleans MUST BE upcase words.
.b $> elastico 'nmingott AND machine:*metric*'

# Elaboration respect to the previous maching all line where "nmingott"
# appers and the machine is a string containing *ana* or *metric*.
# This examples shows that (...) is the syntax for  
# grouping of booleans and that it is not necessary to write
# (machine:*metric* OR machine:*ana*) in full.
.b $> elastico 'nmingott AND machine:(*metric* OR *ana*)'

# See last logs in psmetrico01
.b $> elastico 'machine:psmetric01'

# See the last 200 log lines in psmetric01
.b $> elastico -l 200 'machine:psmetric01'

# See the log lines that best metch a string,
# return results according to Elasticsearch 'relevance' 
# algorithm, not by date. In general, more time the string
# is matched in the log line the more a line is 'relevant'.
.b $> elastico -S 'ana*' 

# Hilight the search results 
.b $> elastico -l 20 -h 'wilko'

# Autocomplete only for a specific number of characters
# In this case all 'psana' followed by 3 characters.
.b $> psana -h 'psana???'

HERED

# Example of Lucene Query sintax to Elasticsearch CURL 
# curl -XGET 'http://psmetric04:9200/lclslogs/_search?pretty=true' -H 'Content-Type: application/json' -d '{"query": { "query_string": { "default_field":"src", "query":"psmetric01"     }      }     }'

# ==========================================================
# Global variables determined with defaul values 
# that can be modified by command line parameters.
# =========================================================
#
# Upper limit to the number of output lines required. 
# This value is overriddend if the parameter "-t" is set.
# 
$LIMIT = 20 
#
# If true values are returned sorted by date, if false
# the lines are returned by Elasticsearch 'relevance' sort.
#
$SORTED = true
# 
# 
$HIGHLIGHT = false
# 
# If this variable is set to 'true' then the variable $MYDEBUG_VALS 
# is printed in output. MYDEBUG_VALS contains various intermediate 
# results of interest.
#  
$MYDEBUG = false 
$MYDEBUG_VALS = {}
#
# For filtering according to date 
# Selecte all values in interval [$DATE0, $DATE1]
# The two values are in milliseconds. "$TIME_FILTER" 
# is true iff the time window has been specified on the command line.
$TIME_FILTER = false;
$DATE0 = 0
$DATE1 = ((Time.now.to_i)*1000)

# =========================================================


# -] Make a string bold for the terminal 
def bolden(str)
  out = "\033[1m" + str + "\033[0m"
end

# -] replace blocks <em> ... </em> with Bash escape code
#    for bold.
def emphasis(str)
  out = str.gsub /<em>(.*?)<\/em>/, "\033\[1m\\1\033\[0m"
end

def dateTimeToPST(dateTime)
  d = dateTime
  # if the timezone is already "-08:00" do nothing
  return d if d.zone == "-08:00" 
  out = DateTime.new(d.year, d.month, d.day, d.hour, d.minute, d.second, '-08:00')
end 


# -] function that analyzes the time string and return 
#    two DateTime objects representing the time window of interest.
# 
# IN: 'timeStr' : can be something like:
#      "2d"
#      "5h" 
#      "10m"    
#      "2018-dec-06-10:30__+2d"
#      "2018-dec-06-10:30__2018-dec-08"
#      "06-dec__15-dec"
#      .... 
# OUT: [dateA, dateB] 
#      date[A|B] are DateTime objects, they are not ordered, dateA can be larger than dateB
# 
def workOnTimeString(timeStr) 
  str = timeStr.dup 
  # timeStr e' del tipo: 1h, 5d, etc. 
  if  (m = str.match /^(?<val>\d+)(?<unit>[mhd])$/) then 
    val = m['val'].to_i
    seconds = {'m' => 60, 'h' => 60*60, 'd' => 60*60*24}
    # tempo corrente come epoch in secondi 
    # 
    rhsTime = DateTime.now
    lhsTime = rhsTime.to_time.to_i - (m['val'].to_i * seconds[m['unit']])
    lhsTime = lhsTime + DateTime.now.to_time.utc_offset
    lhsTime = DateTime.strptime(lhsTime.to_s, "%s")
    # 
  elsif (m = str.match /^(?<lhs>.*)__(?<rhs>.*)$/) then
    lhs = m['lhs'].dup.strip
    rhs = m['rhs'].dup.strip
    # puts "lhs: #{lhs}"
    # puts "rhs: #{rhs}"
    # 
    # lhs is always a point in time, that can be expressed as 
    # 2018-dec-06, dec-06, 06-10:30:31, 05-10:30
    # if YYY is not set is the current year 
    # if MM is not set is the current month
    # if SS is not set is zero 
    # if HH:MM is not set it is 00:00 (the first minute of the day)
    begin 
    lhsTime = nil
    # full date : 2018-dec-06-10:30
    if lhs.match /^\d{4}-\w{3}-\d{1,2}-\d{1,2}:\d{1,2}$/ then 
      lhsTime = DateTime.strptime(lhs, '%Y-%b-%d-%H:%M')
    # no year : dec-06-10:30 
    elsif lhs.match /^\w{3}-\d{1,2}-\d{1,2}:\d{1,2}$/ then 
      lhsTime = DateTime.strptime(lhs, '%b-%d-%H:%M')
    # no time : 2018-dec-06 
    elsif lhs.match /^\d{4}-\w{3}-\d{1,2}$/ then 
      lhsTime = DateTime.strptime(lhs, '%Y-%b-%d')
    # no year, no time : dec-06
    elsif lhs.match /^\w{3}-\d{1,2}$/ then 
      lhsTime = DateTime.strptime(lhs, '%b-%d')
    # only time : 15:30
    elsif lhs.match /^\d{1,2}:\d{1,2}$/ then 
      lhsTime = DateTime.strptime(lhs, '%H:%M')
    else
      STDERR.puts "Error, time format not recognized."
      exit(1)
    end
    # puts "lhsTime: #{lhsTime}"
    rescue => ex 
      STDERR.puts "Exception in parsing dates, check e.g. month names."
      exit(3)
    end

    # 
    # rhs can be a point in time, or a delta respect to lhs time.
    # 
    # if rhs is a delta it a can be: e.g. +1d, 5h, 20h, -12d ... 
    # 
    begin 
    rhsTime = nil 
    if (m = rhs.match(/^(?<sign>[+-])(?<val>\d+)(?<unit>[mhd])$/)) then
      seconds = {'m' => 60, 'h' => 60*60, 'd' => 60*60*24}
      if m['sign'] == '+' then 
        # binding.pry
        rhsTime = lhsTime.to_time.to_i + (m['val'].to_i * seconds[m['unit']])
        rhsTime = DateTime.strptime(rhsTime.to_s, "%s")
      else
        rhsTime = lhsTime.to_time.to_i - (m['val'].to_i * seconds[m['unit']])        
        rhsTime = DateTime.strptime(rhsTime.to_s, "%s")
      end
    # 
    # Now we see the case in which rhs if fully described 
    # complete: 2018-dec-06-10:31
    elsif rhs.match /^\d{4}-\w{3}-\d{1,2}-\d{1,2}:\d{1,2}$/ then 
      rhsTime = DateTime.strptime(rhs, '%Y-%b-%d-%H:%M')
    # no year : dec-06-10:30 
    elsif rhs.match /^\w{3}-\d{1,2}-\d{1,2}:\d{1,2}$/ then 
      rhsTime = DateTime.strptime(rhs, '%b-%d-%H:%M')
    # no time : 2018-dec-06 
    # in this case the time is the last minute of the day.
    elsif rhs.match /^\d{4}-\w{3}-\d{1,2}$/ then 
      tmp = DateTime.strptime(rhs, '%Y-%b-%d')
      rhsTime = DateTime.new(tmp.year, tmp.month, tmp.day, 23, 59, 59)
    # no year, no time : dec-06
    elsif rhs.match /^\w{3}-\d{1,2}$/ then 
      tmp = DateTime.strptime(rhs, '%b-%d')
      rhsTime = DateTime.new(tmp.year, tmp.month, tmp.day, 23, 59, 59)
    # only time : 15:30
    elsif rhs.match /^\d{1,2}:\d{1,2}$/ then 
      rhsTime = DateTime.strptime(rhs, '%H:%M')
    # 
    # Finally the case in which 'rhs' has not a recognizable format 
    else 
      STDERR.puts "Error, time format not recognized."
      exit(1) 
    end
    rescue => ex 
      STDERR.puts "Exception in parsing dates, check e.g. month names."
      exit(3)
    end
    # puts "rhsTime: #{rhsTime}"
    # exit (2)
  else
    STDERR.puts "Error, the time string '#{timeStr}' for parameter '-t' has an unknown format."
    exit(1);
  end
  # 
  # Return the two time limits. The first time is always before (in time) respect to the second one.
  # 
  lhsTime = dateTimeToPST(lhsTime)
  rhsTime = dateTimeToPST(rhsTime)
  if lhsTime == rhsTime then 
    STDERR.puts "Error. The time interval is empty, the search will be empty."
    exit(1)
  elsif lhsTime < rhsTime then
    out = [lhsTime, rhsTime]
    $MYDEBUG_VALS['lhsTime'] = lhsTime;
    $MYDEBUG_VALS['rhsTime'] = rhsTime;
  else
    out = [rhsTime, lhsTime]
    $MYDEBUG_VALS['lhsTime'] = rhsTime;
    $MYDEBUG_VALS['rhsTime'] = lhsTime;
  end
  out
end


# -] If there are not arguments print error message and quit
#
if ARGV.length == 0 then
  STDERR.puts "Error, this program requires at least one argument. "
  STDERR.puts "Use arg '-h' to see the documentation. "
  exit(1)
end 

# -] If "-h" is first argument show the documentation
#
if (ARGV.length == 1) and (ARGV[0] == "-h") then 
  doc2 = doc.dup
  doc2.gsub! /<b>(.*?)<\/b>/, bolden('\1')
  doc2.split(/\n/).each do |l|
    if l.match(/^\.b/) then 
      tmp = l.sub(/^\.b /, "")
      puts " " + bolden(tmp)
    else
      puts " " + l
    end
  end
  # puts doc; 
  exit(0); 
end 

# -] Parameters consistency check.
#    parameters "-t" and "-l" can not be set on the same query, they
#    give inconsistent directions because "-t" defines implicitely the number of lines
#    it needs to get, "-l" does it explicitely.
# 
if ( ARGV.include?("-t") and 
     ARGV.include?("-l") ) then 
  STDERR.puts "Error, parameters '-l' and '-t' are conflicting and can't be put on the same query."
  exit(1)
end 

# -] Parametro "-d" 
#    per l'attivazione dei messaggi di debug
if ARGV.include?("-d") then 
  $MYDEBUG = true;
end 



# -] get parameters values and set constants 
# 
(0..(ARGV.length-2)).each do |idx|
  par = ARGV[idx]
  if par == "-S" then 
    $SORTED = false;
  elsif par == "-h" then 
    $HIGHLIGHT = true
  elsif par == "-H" then 
    $HIGHLIGHT = false
  #
  # "-l" : limit number of results 
  elsif par == "-l" then
    if ARGV[idx+1] == nil then 
      STDERR.puts "Error, an argument is needed after parameter '-l'."
      exit(1)
    end
    val = ARGV[idx+1]
    if (not val.match /\d+/) then 
      STDERR.puts "Error, argument of '-l' is required to be a positive integer."
      exit(1)
    end
    if (val.to_i > 10_000) then 
      STDERR.puts "Error, at the moment the maxium number of line retrivable is 10_000."
      exit(1)
    end
    $LIMIT = ARGV[idx+1].to_i
  # 
  # "-t" : time window for selected results 
  elsif par == "-t" then 
    if ARGV[idx+1] == nil then 
      STDERR.puts "Error, an argument is needed after parameter '-t'."
      exit(1)      
    end
    # get the DateTime objects representing the time interval of interest
    dt0, dt1 = workOnTimeString(ARGV[idx+1])
    # convert the tims in milisseconds Epochs and set the globa variables 
    $TIME_FILTER = true;
    $DATE0 = (dt0.to_time.to_i * 1_000)
    $DATE1 = (dt1.to_time.to_i * 1_000)    
    # exit(1);
  end  
end 


# -] Lucene Query String is always the last argument in the shell command line 
# 
LQSTR = ARGV[-1].dup


# Accepts a Lucene query string "lucQstr", calls Elasticsearch via "curl" 
# and return the response as a string.
# We use "curl" to avoid the load of extra libraries, this may be changed.
def curlQuery(lucQstr="*", sorted: true, size: 20, highlight: false, count: false )

  if sorted then 
    sortedStr = ',"sort": {"date": {"order": "desc"}}  '
  else
    sortedStr = ""
  end

  if highlight then 
    highlightStr = ',"highlight": { "fields": { "src": {} } }'
  else
    highlightStr = ""
  end

  # The operation type can be "_search", the get the results 
  # of "_count" to count the possible results 
  opType = "_search"
  if count then 
    opType = "_count"
    sortedStr = ""
    highlightStr = ""
  else
    opType = "_search?size=#{size}"
  end

  # The command include newlines and extra-spaces which are extremely useful
  # for readability, but then they must be removed.
  # -s : silent mode, does not show the progress bar 
  cmd = %Q[ curl -s -XGET 'http://psmetric04:9200/lclslogs/#{opType}' 
                 -H 'Content-Type: application/json' 
                 -d '{ "query": { 
                        "bool": { 
                          "must": { 
                            "query_string": { 
                                      "default_field" : "src", 
                                      "query"         : "#{lucQstr}" 
                             }
                           }, 
                           "filter": { 
                              "range": { 
                                 "date": { 
                                     "gt" : "#{$DATE0}", 
                                     "lt" : "#{$DATE1}" 
                                 } 
                              }
                           }
                         } 
                        }
                       #{sortedStr}
                       #{highlightStr}
                     } ' ]


  # Store the query for debug purposes 
  if count == true then 
    $MYDEBUG_VALS['counterQuery'] = cmd.dup;
  else 
    $MYDEBUG_VALS['query'] = cmd.dup;
  end

  # Remove newlines 
  cmd.gsub! /\n/, " ";
  # Remove extra spaces 
  cmd.gsub! /\s+/, " ";

  # puts "DBG> #{cmd}" 
  out = `#{cmd}`
  # puts "DBG> #{out}" 
  out 
end


# -] Buffer containing all lines that will be printed 
lineBuffer = []

# -] If the search is by date get the number of results before
#    actually get them.     
#    The result is something similar to this:
#    {"count":19,"_shards":{"total":5,"successful":5,"skipped":0,"failed":0}}
# 
if $TIME_FILTER == true then 
  tmp = curlQuery( "* AND ( #{LQSTR} )", count: true)
  totalResultsByTime = JSON.parse(tmp)["count"].to_i
  # puts "Total documents to retrive: #{totalResultsByTime}."
  $MYDEBUG_VALS['counterQueryResult'] = tmp
  $MYDEBUG_VALS['numDocPerTimeWin'] = totalResultsByTime
  if (totalResultsByTime >= 10_000) then 
    STDERR.puts "Error, the number of loglines to get would be #{totalResultsByTime}."
    STDERR.puts "Please refine your search criteria, the maximum number of lines allowed in output is 10_000."
    exit(1)
  else 
    $LIMIT = totalResultsByTime;
  end 
end

# -] Make the query to Elasticsearch and store all results 
#    in the buffer "lineBuffer".
# 
tmp = curlQuery( "* AND ( #{LQSTR} )", size: $LIMIT, 
                 sorted: $SORTED, highlight: $HIGHLIGHT, count: false)
JSON.parse(tmp)['hits']['hits'].each do |el|
  if $HIGHLIGHT then
    lineBuffer.push( el['highlight']['src']  )
  else
    lineBuffer.push( el['_source']['src'] )
  end
end; nil 

STDERR.puts "=== Development version of Elastico, unstable, don't use ===="
# -] Printer all lines in "lineBuffer".
lineBuffer.reverse.each do |l|
  next if l.nil?
  if $HIGHLIGHT then 
    puts emphasis(l[0])
  else
    puts l
  end
end 
STDERR.puts "=========== Development version of 'elastico', unstable, don't use ===="


# -] Print to STDERR debug informations if parameter "-d" is in ARGV.
#
if ($MYDEBUG == true) then 

  STDERR.puts <<EOD

  ========= Debug Informations ========================================================
  -] Limit the number of docuements to: $LIMIT 
     => #{$LIMIT}

  -] Command line arguments ARGV
     => #{ARGV}

  -] left side of the time window selected (lhs)
     => #{$MYDEBUG_VALS['lhsTime']}

  -] right side of the time window selected (rhs)
     => #{$MYDEBUG_VALS['rhsTime']}

  -] Epoch values in millisec sent to Elasticsearch time range filter window [$DATE0, $DATE1]
     => [ #{$DATE0}, #{$DATE1} ]

  -] Expolorative query for Elastic to count results per time window (if specified parameter '-t')
     => #{$MYDEBUG_VALS['counterQuery']}

  -] Explorative query result
     => #{$MYDEBUG_VALS['counterQueryResult']}

  -] Curl query for Elastic, to get results
     => #{$MYDEBUG_VALS['query']}

  ====================================================================================

EOD
end 







