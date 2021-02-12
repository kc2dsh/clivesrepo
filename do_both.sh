#!/bin/bash

# We need two settings for this
## 
#   do_env_build.sh bucketname venv_name

if [ "$#" -ne 2 ]; then
    echo "Illegal number of parameters"
    echo "Call it like this:"
    echo
    echo "do_env_build.sh bucketname venv_name"
    echo 
    echo "(it will create the venv for you)"
    exit 64
fi

BUCKET=$1
VENV=$2

BASE=${PWD}
DEPLOY=s3://${BUCKET}/lib/deploy/${VENV}

do_move () {
   for f in ${@:3}; do
      find ${1} -name ${f} | xargs -I {} mv '{}' ${2}/
   done
}

do_aws_copy_lib () {
   echo aws s3 cp --recursive ${1}/ ${2}/${1}/
   aws s3 cp --recursive ${1}/ ${2}/${1}/
}

# Clean out aws environment...
aws s3 rm --recursive ${DEPLOY}

do_first_env () {
   # first, set up the pyhthon environment...
   python3 -m venv ${VENV}
   cd ${VENV}
   source bin/activate
   pip install -U pip
   #pip install tensorflow-cpu==2.3.0
   pip install tensorflow-cpu==2.4.0
   pip install pyclean
   pyclean lib
   pip uninstall -y pyclean

   # second - move the files around in the python environment...
   cd lib/python3.8

   mkdir -p lib/prepreload
   mkdir -p lib/preload
   mkdir -p lib/load
   mkdir -p lib/numpy
   mkdir -p lib/other

   do_move site-packages/numpy.libs lib/preload "libquadmath-* libz-*"
   do_move site-packages/numpy.libs lib/numpy "libopenblasp-* libgfortran-*"
   do_move site-packages/tensorflow lib/preload libtensorflow_framework.so.2
   do_move site-packages/tensorflow lib/load _pywrap_tensorflow_internal.so
   do_move site-packages/tensorflow lib/other fast_tensor_util.so _op_def_util.so pybind_for_testing.so _python_memory_checker_helper.so _pywrap_kernel_registry.so _pywrap_python_api_dispatcher.so _pywrap_stat_summarizer.so _pywrap_tfcompile.so _pywrap_tf_item.so _pywrap_transform_graph.soo

   # third, copy all the moved .so files to aws
   #~/python-envs/do_aws_file_copy.sh ${BUCKET} ${VENV}

   for l in `ls lib` ; do
      do_aws_copy_lib lib/${l} ${DEPLOY}
   done

   #fourth copy the lambda function into site-packages
   sed "s/__DEPLOYMENT__/${VENV}/g;" ~/python-envs/lambda_function.txt > site-packages/lambda_function.py
   #cp ~/python-envs/lambda_function.py site-packages

   # fifth - create the deployment package .zip file and copy to aws
   cd site-packages

   # tidy up a bunch of things that we don't need in an execution-only env...
   rm -rf pip*
   rm -rf setuptools*
   rm -rf wheel*
   rm -rf tensorflow/include
   rm -rf tensorboard*
   rm -rf tensorflow_estimator*
   find . -type d -name tests -print0 | xargs -0 -I {} /bin/rm -rf "{}"
   find . -type d -name include -print0 | xargs -0 -I {} /bin/rm -rf "{}"

   deactivate

   cd ${BASE}
   rm -f ${BASE}/sp-${VENV}.zip 
   cd ${VENV}/lib/python3.8/site-packages
   zip -r ${BASE}/sp-${VENV}.zip .

}

do_second_env () {
   cd ${BASE}

   VENVADDITIONAL=${VENV}-additional
   python3 -m venv ${VENVADDITIONAL}
   cd ${VENVADDITIONAL}
   source bin/activate

   pip install -U pip
   pip install future
   pip install joblib
   pip install pandas
   pip install pyarrow
   pip install pytz
   pip install sklearn
   pip install tensorflow-addons
   pip install typeguard
   pip install fastavro
   
   pip install pyclean
   pyclean lib
   pip uninstall -y pyclean
   
   # second - move the files around in the python environment...
   cd lib/python3.8
   
   mkdir -p lib/prepreload
   mkdir -p lib/preload
   mkdir -p lib/sklearn
   mkdir -p lib/scipy
   mkdir -p lib/scipy_other
   mkdir -p lib/pyarrow
   mkdir -p lib/fastavro
   mkdir -p lib/pandas
   
   do_move site-packages/scipy.libs lib/preload "libopenblasp-*"
   do_move site-packages/scipy.libs lib/prepreload "libgfortran-*"

   do_move site-packages/pyarrow lib/preload "libparquet.so.* libarrow.so.*"
   do_move site-packages/pyarrow lib/pyarrow "lib*.so.*"

   do_move site-packages/fastavro lib/fastavro "*.so*"

   cd site-packages

   # Here - there's a lot we can trim back from sklearn, as we only use sklearn.metrics._classification
   rm -rf numpy*
   rm -rf pip*
   rm -rf setuptools*
   rm -rf wheel*
   rm -rf sklearn/ensemble*
   rm -rf sklearn/cluster*
   rm -rf sklearn/neighbors*
   find . -type d -name tests -print0 | xargs -0 -I {} /bin/rm -rf "{}"
   find . -type d -name include -print0 | xargs -0 -I {} /bin/rm -rf "{}"

   cd ..
   for l in `ls lib` ; do
      do_aws_copy_lib lib/${l} ${DEPLOY}
   done


   cd ${BASE}/${VENVADDITIONAL}/lib/python3.8/site-packages
   zip -r ${BASE}/sp-${VENV}.zip .
   
   cd ..
   for l in `ls lib` ; do
      do_aws_copy_lib lib/${l} ${DEPLOY}
   done
   
   deactivate
}

do_fakes () {

   cd /home/clive/python-envs/fake-packages
   echo HERE-------------------------------------------- zip -r ${BASE}/sp-${VENV}.zip .
   zip -r ${BASE}/sp-${VENV}.zip .

}

do_first_env
do_second_env
#do_fakes


aws s3 cp ${BASE}/sp-${VENV}.zip s3://perrystreet.net/lib/deploy/${VENV}/

cd ${BASE}

# lastly, do a test
aws lambda update-function-code --function-name test-runtime-3 --s3-bucket ${BUCKET} --s3-key lib/deploy/${VENV}/sp-${VENV}.zip
aws lambda invoke --function-name test-runtime-3 --payload $(echo -n '{"foo": "bar"}' | base64) out.txt

# lastly, do a test (echo for now...)
echo aws lambda update-function-code --function-name test-runtime-3 --s3-bucket ${BUCKET} --s3-key lib/deploy/${VENV}/sp-${VENV}.zip
echo aws lambda invoke --function-name test-runtime-3 --payload $(echo -n '{"foo": "bar"}' | base64) ../out.txt

